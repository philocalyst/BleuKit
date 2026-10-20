<*
 DMS wire helpers: one JSON line per reply, request parameters read the way
 DankMaterialShell's `dankgo/ipc/params` reads them, and the shapes every module
 shares (`SuccessResult`).

 Field names are written by hand, one per Go `json` tag. Sources:
 `core/internal/server/models/types.go` (SuccessResult), `dankgo/ipc/params/params.go`.
 Module-specific shapes live in the module file.
*>
module dmsd::wire;
import bleu::json, bleu::error;

<*
 A JSON value being written into temporary memory. Declare it in place and call
 `begin` on it: the writer keeps a pointer to the text, so it must not move.
*>
struct Line
{
	DString text;
	json::JsonWriter writer;
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
fn void? key_string(json::JsonWriter* writer, String key, String value)
{
	writer.key(key)!;
	writer.put_string(value)!;
}

<* `"key": true|false`. *>
fn void? key_bool(json::JsonWriter* writer, String key, bool value)
{
	writer.key(key)!;
	writer.put_bool(value)!;
}

<* `"key": <integer>`. *>
fn void? key_int(json::JsonWriter* writer, String key, long value)
{
	writer.key(key)!;
	writer.put_int(value)!;
}

<* `"key": <unsigned integer>`. *>
fn void? key_uint(json::JsonWriter* writer, String key, ulong value)
{
	writer.key(key)!;
	writer.put_uint(value)!;
}

<* `"key": ["a","b"]`; an empty list is `[]`, never `null`, as Go writes an empty non-nil slice. *>
fn void? key_strings(json::JsonWriter* writer, String key, String[] values)
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
 Request parameters. The error texts are dankgo's (`params/params.go:12`):
 "missing or invalid '<key>' parameter". Numbers are read as Go reads them,
 as float64 and truncated to an integer.
*>
fn String? param_string(std::encoding::json::Object* params, String key)
{
	if (try value = json::read::get_string(params, key)) return value;
	return invalid_param(key)~;
}

<* A required number, truncated toward zero the way `params.Int` does. *>
fn long? param_int(std::encoding::json::Object* params, String key)
{
	if (try value = json::read::get_double(params, key)) return (long)value;
	return invalid_param(key)~;
}

<* A required number as a float64. *>
fn double? param_float(std::encoding::json::Object* params, String key)
{
	if (try value = json::read::get_double(params, key)) return value;
	return invalid_param(key)~;
}

<* A required boolean. *>
fn bool? param_bool(std::encoding::json::Object* params, String key)
{
	if (try value = json::read::get_bool(params, key)) return value;
	return invalid_param(key)~;
}

<* An optional boolean: `fallback` when absent or not a boolean (`params.BoolOpt`). *>
fn bool opt_bool(std::encoding::json::Object* params, String key, bool fallback)
{
	if (try value = json::read::get_bool(params, key)) return value;
	return fallback;
}

<* An optional integer: `fallback` when absent or not a number (`params.IntOpt`). *>
fn long opt_int(std::encoding::json::Object* params, String key, long fallback)
{
	if (try value = json::read::get_double(params, key)) return (long)value;
	return fallback;
}

<* An optional float64: `fallback` when absent or not a number (`params.FloatOpt`). *>
fn double opt_float(std::encoding::json::Object* params, String key, double fallback)
{
	if (try value = json::read::get_double(params, key)) return value;
	return fallback;
}

fn fault invalid_param(String key) @private
{
	return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "missing or invalid '%s' parameter", key);
}
</content>
