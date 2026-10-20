<*
 The line-JSON envelope of the Bleu daemons: one JSON document per line.

 Requests arrive as `{"id":N,"method":"name","params":{...}}`. Replies are
 `{"id":N,"result":value}` or `{"id":N,"error":"message"}`. Events are
 `{"id":N,"result":{"service":"name","data":value}}`. Every frame is one line
 terminated by LF and is written without an intermediate tree: the value is
 streamed into the writer, or a pre-serialised fragment is inserted.

 A frame is a document of its own: each `write_*` call starts a new one with
 `JsonWriter.restart`, so frames can be written back to back into one writer.
 The writer must be compact (indent 0), because a line may not contain LF.
*>
module bleu::json::envelope;
import bleu::error;
import bleu::json;
import bleu::json::read;
import std::encoding::json;
import std::collections::object;

<*
 Largest request line accepted, in bytes. A longer line is refused before it
 is parsed, bounding the memory one peer can make the daemon allocate.
*>
const usz MAX_FRAME = 1 << 20;

<*
 A parsed request. `method` and `params` point into `root`, the parsed tree,
 which the caller releases with `free`.
*>
struct Request
{
	long id; // an integer that JavaScript can represent exactly
	String method;
	Object* params; // the params object, or null when the request has none
	Object* root; // owns the parsed tree
}

<*
 Parse one request line. The line is strict JSON (no comments) and at most
 `MAX_FRAME` bytes. Nesting is bounded by the parser's own depth limit.

 @param allocator : "Owner of the parsed tree; released by `Request.free`"
 @param line : "One line of input, without its terminating LF"
 @return? error::OUT_OF_RANGE : "The line is longer than MAX_FRAME, or the id is not an exact integer"
 @return? error::PROTOCOL : "The line is not JSON, or its top level is not an object, or params is not an object"
 @return? error::INVALID_ARGUMENT : "The id or method is missing or of the wrong type; error::last() names it"
*>
fn Request? parse_request(Allocator allocator, String line)
{
	if (line.len > MAX_FRAME) return error::raise(error::OUT_OF_RANGE, error::Domain.INTERNAL, 0, "request of %d bytes exceeds the %d byte limit", line.len, MAX_FRAME)~;
	Object*? parsed = json::parse(allocator, line, json::JsonFlavor.JSON);
	if (catch parsed) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "request is not strict JSON")~;
	Object* root = parsed;
	bool handed_over = false;
	defer if (!handed_over) root.free();
	if (!root.is_map()) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "request is not a JSON object")~;
	long id = read::get_int(root, "id")!;
	if (id > read::MAX_EXACT_INTEGER || id < -read::MAX_EXACT_INTEGER) return error::raise(error::OUT_OF_RANGE, error::Domain.INTERNAL, 0, "request id %d is not an exact JavaScript integer", id)~;
	String method = read::get_string(root, "method")!;
	Object* params = read::present(root, "params")!;
	if (params && !params.is_map()) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "request params is not an object")~;
	handed_over = true;
	return { id, method, params, root };
}

<* Release the parsed tree of a request. The request's strings are invalid afterwards. *>
fn void Request.free(&self) => self.root.free();

<*
 Start a frame: `{"id":id,` followed by the member `name` whose value the
 caller writes next. Refused when the writer is indenting.
*>
fn void? begin_frame(json::JsonWriter* writer, long id, String name)
{
	if (writer.indent != 0) return error::raise(error::INVALID_STATE, error::Domain.INTERNAL, 0, "line frames need a compact writer")~;
	writer.restart()!;
	writer.begin_object()!;
	writer.key("id")!;
	writer.put_int(id)!;
	writer.key(name)!;
}

<* Close a frame and terminate its line. *>
fn void? end_frame(json::JsonWriter* writer, bool closes_result_object)
{
	if (closes_result_object) writer.end_object()!;
	writer.end_object()!;
	writer.emit("\n")!;
}

<*
 Write a success reply, `{"id":id,"result":value}`, with `value` serialised
 straight into the frame.

 @param value : "A plain-data value; see bleu::json::write"
*>
macro void? write_result(json::JsonWriter* writer, long id, value, json::Options options = json::DEFAULT_OPTIONS)
{
	begin_frame(writer, id, "result")!;
	json::write(writer, value, options)!;
	return end_frame(writer, false);
}

<*
 Write a success reply whose value is an already serialised JSON fragment, for
 example a snapshot that many clients receive. The fragment is validated.

 @param fragment : "One complete JSON value"
 @return? error::INVALID_ARGUMENT : "The fragment is not one JSON value"
*>
fn void? write_result_raw(json::JsonWriter* writer, long id, String fragment)
{
	begin_frame(writer, id, "result")!;
	writer.put_raw(fragment)!;
	return end_frame(writer, false);
}

<*
 Write an error reply, `{"id":id,"error":"message"}`.

 @param message : "Human-readable text, any UTF-8"
*>
fn void? write_error(json::JsonWriter* writer, long id, String message)
{
	begin_frame(writer, id, "error")!;
	writer.put_string(message)!;
	return end_frame(writer, false);
}

<*
 Write an event frame, `{"id":id,"result":{"service":service,"data":value}}`.

 @param service : "The service that produced the event"
 @param value : "A plain-data value; see bleu::json::write"
*>
macro void? write_event(json::JsonWriter* writer, long id, String service, value, json::Options options = json::DEFAULT_OPTIONS)
{
	begin_frame(writer, id, "result")!;
	writer.begin_object()!;
	writer.key("service")!;
	writer.put_string(service)!;
	writer.key("data")!;
	json::write(writer, value, options)!;
	return end_frame(writer, true);
}

<*
 Write an event frame whose data is an already serialised JSON fragment.

 @param service : "The service that produced the event"
 @param fragment : "One complete JSON value"
 @return? error::INVALID_ARGUMENT : "The fragment is not one JSON value"
*>
fn void? write_event_raw(json::JsonWriter* writer, long id, String service, String fragment)
{
	begin_frame(writer, id, "result")!;
	writer.begin_object()!;
	writer.key("service")!;
	writer.put_string(service)!;
	writer.key("data")!;
	writer.put_raw(fragment)!;
	return end_frame(writer, true);
}
