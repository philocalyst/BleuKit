<*
 Helpers every command uses to write its reply and to wait for its operation.
*>
module bleu::registry;
import std::time, std::collections::maybe, std::core::string, bleu::error, bleu::json, bleu::operation;

<* Write the success object `{"ok": true}`. Commands add their own fields before it when they need to. *>
fn void? write_ok(json::JsonWriter* out)
{
	out.begin_object()!;
	out.key("ok")!;
	out.put_bool(true)!;
	return out.end_object();
}

<*
 Wait for `operation` to finish and return its value. When it is still running
 after `timeout` it is cancelled, so the worker stops at its next check.

 @param timeout : "Longest to wait; the command's own timeout"
 @return? TIMEOUT : "The operation did not finish in time; it was cancelled"
 @return? error::CANCELLED : "The operation was cancelled"
*>
fn Value? await(Operation{Value}* operation, Duration timeout)<Value>
{
	Value? value = operation.wait(timeout);
	if (catch err = value)
	{
		if (err == TIMEOUT) operation.cancel();
		String detail = operation.detail().message();
		if (!detail.len) detail = "the operation failed without a message";
		return error::raise(err, error::Domain.INTERNAL, 0, "%s", detail)~;
	}
	return value;
}

<*
 Write the success object with one value: `{"ok": true, "<key>": value}`.
 The value is written with bleu_json's reflection, so enums are lower_snake strings.

 @param key : "The member name of the value"
 @param value : "Any plain-data value"
*>
macro void? write_value(json::JsonWriter* out, String key, value)
{
	out.begin_object()!;
	out.key("ok")!;
	out.put_bool(true)!;
	out.key(key)!;
	json::write(out, value)!;
	return out.end_object();
}

<*
 The enum member whose name, in lower_snake, is `text`. Matching ignores ASCII case,
 so `"power_saver"` and `"POWER_SAVER"` both name `POWER_SAVER`.

 @return? error::INVALID_ARGUMENT : "No member of the enum has that name"
*>
fn Enum? parse_enum(String text)<Enum>
{
	for (usz i = 0; i < Enum::len; i++)
	{
		Enum candidate = Enum::from_ordinal(i);
		if (same_name(string::tformat("%s", candidate), text)) return candidate;
	}
	return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "unknown value: %s", text)~;
}

<* Whether the two names are equal when ASCII letters are compared without case. *>
fn bool same_name(String upper, String text) @private
{
	if (upper.len != text.len) return false;
	for (usz i = 0; i < upper.len; i++)
	{
		if ((upper[i] | 0x20) != (text[i] | 0x20)) return false;
	}
	return true;
}

<*
 The string member `key`, or `fallback` when the request leaves it out.

 @return? error::INVALID_ARGUMENT : "The member is present but not a string"
*>
fn String? string_or(json::read::Params params, String key, String fallback)
{
	Maybe{String} given = params.optional_string(key)!;
	return given.has_value ? given.value : fallback;
}
