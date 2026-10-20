<*
 DMS wire helpers: one JSON line per reply, request parameters read the way
 DankMaterialShell's `dankgo/ipc/params` reads them, and the shapes every module
 shares (`SuccessResult`).

 Field names are written by hand, one per Go `json` tag. Sources:
 `core/internal/server/models/types.go` (SuccessResult), `dankgo/ipc/params/params.go`.
 Module-specific shapes live in the module file.
*>
module dmsd::wire;
import bleu::json, bleu::error, bleu::ipc;

<*
 A JSON value being written into temporary memory. Declare it in place and call
 `begin` on it: the writer keeps a pointer to the text, so it must not move.
*>
struct Line
{
	DString text;
	bleu::json::JsonWriter writer;
}

<* Start an empty value in `allocator`. *>
fn void Line.begin(&self, Allocator allocator)
{
	self.text.init(allocator);
	self.writer.init_dstring(&self.text);
}

<* The finished value as one line, valid as long as the allocator's memory. *>
fn String? Line.finish(&self)
{
	self.writer.finish()!;
	return self.text.str_view();
}

<* `"key": "value"`. *>
fn void? key_string(bleu::json::JsonWriter* writer, String key, String value)
{
	writer.key(key)!;
	writer.put_string(value)!;
}

<* `"key": true|false`. *>
fn void? key_bool(bleu::json::JsonWriter* writer, String key, bool value)
{
	writer.key(key)!;
	writer.put_bool(value)!;
}

<* `"key": <integer>`. *>
fn void? key_int(bleu::json::JsonWriter* writer, String key, long value)
{
	writer.key(key)!;
	writer.put_int(value)!;
}

<* `"key": <unsigned integer>`. *>
fn void? key_uint(bleu::json::JsonWriter* writer, String key, ulong value)
{
	writer.key(key)!;
	writer.put_uint(value)!;
}

<* `"key": ["a","b"]`; an empty list is `[]`, never `null`, as Go writes an empty non-nil slice. *>
fn void? key_strings(bleu::json::JsonWriter* writer, String key, String[] values)
{
	writer.key(key)!;
	writer.begin_array()!;
	foreach (value : values) writer.put_string(value)!;
	writer.end_array()!;
}

<*
 Build DMS's `SuccessResult`: `{"success":true,"message":"..."}`. `message` is
 left out when empty (Go's `omitempty`).
 @return "The line, in `allocator`"
*>
fn String? success_result(Allocator allocator, String message)
{
	Line line;
	line.begin(allocator);
	line.writer.begin_object()!;
	key_bool(&line.writer, "success", true)!;
	if (message.len > 0) key_string(&line.writer, "message", message)!;
	line.writer.end_object()!;
	return line.finish();
}

<*
 Answer `call` with the DMS success result for `message`.
 @return? error::INVALID_STATE : "The request was already answered"
*>
fn void? respond_success(ipc::Call* call, String message)
{
	call.respond_raw(success_result(tmem, message)!);
}
