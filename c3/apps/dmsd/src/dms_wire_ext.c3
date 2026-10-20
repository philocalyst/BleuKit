<*
 More DMS wire shapes, for the modules that carry floats, nulls and Go's zero time.

 These extend the `dmsd::wire` module of `dms_json.c3` (a module may span files). Go writes
 a `float64` with the shortest decimal that reads back exactly, a nil pointer as `null`, and
 an unset `time.Time` as `0001-01-01T00:00:00Z`. The helpers below write those forms.
 Source: Go `encoding/json` (`encode.go`, `floatEncoder`, `ptrEncoder`) and `time.Time`'s
 `MarshalJSON` (`time/time.go`), as the DMS structs are encoded.
*>
module dmsd::wire;
import std::collections::object, bleu::error, bleu::json;

<* The text Go writes for a zero `time.Time`: the instant of year 1, which means "not set". *>
const String GO_ZERO_TIME = "0001-01-01T00:00:00Z";

<* `"key": <number>` for a `float64`. *>
fn void? key_double(bleu::json::JsonWriter* writer, String key, double value)
{
	writer.key(key)!;
	writer.put_double(value)!;
}

<* `"key": null`, the value Go writes for a nil pointer or map. *>
fn void? key_null(bleu::json::JsonWriter* writer, String key)
{
	writer.key(key)!;
	writer.put_null()!;
}

<*
 `"key": "0001-01-01T00:00:00Z"`: a `time.Time` that the daemon does not compute. Use it only
 where docs/DMSD.md says the value is not computed; it is Go's zero time, not a guess.
*>
fn void? key_zero_time(bleu::json::JsonWriter* writer, String key)
{
	key_string(writer, key, GO_ZERO_TIME)!;
}

<*
 A required number, read as dankgo's `params.Float` reads it: a missing or non-numeric member is
 the usual `missing or invalid '<key>' parameter` error.
 @return? error::INVALID_ARGUMENT : "The member is missing, null or not a number"
*>
fn double? required_double(Object* params, String key)
{
	if (try value = json::read::get_double(params, key)) return value;
	return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "missing or invalid '%s' parameter", key)~;
}
