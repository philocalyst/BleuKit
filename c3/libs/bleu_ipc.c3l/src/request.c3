<*
 Parsing of one request line into the fields the dispatcher needs.

 Field rules follow dankgo's `Request` (ipc/models.go:12-16) as Go decodes it:
 `id` is an integer (null or absent is 0), `method` is a string (null or absent
 is ""), and `params` is an object (null or absent is empty). Anything else is a
 protocol error with the text `invalid json: ...`.
*>
module bleu::ipc @feat(POSIX);
import std::encoding::json, std::collections::object, bleu::error, bleu::ipc::wire;

<* A request line, decoded. The strings and objects point into the arena given to `parse_request`. *>
struct ParsedRequest
{
	long id;
	String method;
	Object* params;
}

<*
 Parse one request line. The tree is allocated in `arena`.

 @param line : "One line, without its newline; must be UTF-8"
 @param arena : "Owns everything the result refers to"
 @return? error::PROTOCOL : "Not a request. The message (error::last) starts with `invalid json:`"
*>
fn ParsedRequest? parse_request(String line, Allocator arena)
{
	if (!wire::valid_utf8(line))
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "invalid json: input is not UTF-8")~;
	}
	Object*? parsed = json::parse(arena, line, json::JsonFlavor.JSON);
	if (catch err = parsed)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "invalid json: malformed JSON")~;
	}
	Object* root = parsed;
	ParsedRequest request = { .id = 0, .method = "", .params = object::new_obj(arena) };
	if (root.is_null()) return request;
	if (!root.is_map())
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "invalid json: request must be an object")~;
	}
	if (try id_value = root.get("id"))
	{
		if (!id_value.is_null())
		{
			if (!id_value.is_int())
			{
				return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "invalid json: id must be an integer")~;
			}
			// The parser stores integers that fit a long only; larger ones are malformed.
			request.id = (long)id_value.i;
		}
	}
	if (try method_value = root.get("method"))
	{
		if (method_value.is_string())
		{
			request.method = method_value.s;
		}
		else if (!method_value.is_null())
		{
			return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "invalid json: method must be a string")~;
		}
	}
	if (try params_value = root.get("params"))
	{
		if (params_value.is_map())
		{
			request.params = params_value;
		}
		else if (!params_value.is_null())
		{
			return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "invalid json: params must be an object")~;
		}
	}
	return request;
}
