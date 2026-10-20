<*
 Typed reads from a parsed JSON object (std's `Object` tree).

 Requests from the shells are loosely typed: JavaScript has one number type,
 so an integer parameter may arrive as `3.0`. An integral float is therefore
 accepted where an integer is wanted; `3.5` is not. Every getter is safe on any
 input: a missing member, a member of the wrong type, a null or non-object
 parent all come back as an error whose `error::last()` names the key, never
 as a crash.

 The strings returned point into the parsed tree and live as long as it does.
*>
module bleu::json::read;
import bleu::error;
import std::collections::object;
import std::collections::maybe;
import std::math;

<*
 Largest magnitude a JSON integer may have and still be exact in a JavaScript
 number: 2^53. Ids and counters above it are refused, because a peer written
 in JavaScript cannot have sent them exactly.
*>
const long MAX_EXACT_INTEGER = 9_007_199_254_740_992;

<* Refusal of a member that is missing, null or of the wrong JSON type. *>
fn fault wrong_member(String key, String problem) @inline
{
	return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "member '%s' %s", key, problem);
}

<*
 The member `key` of `obj`, or null when it is absent or JSON `null`. Refuses
 a parent that is neither null nor an object, so a request that puts its
 parameters in an array is reported, not read as empty.

 @param obj : "The parent object; null is treated as an empty object"
 @return? error::INVALID_ARGUMENT : "The parent is not an object"
*>
fn Object*? present(Object* obj, String key)
{
	if (!obj || obj.is_null()) return null;
	if (!obj.is_map()) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "member '%s' is looked up in a value that is not an object", key)~;
	if (try found = obj.get(key))
	{
		if (found.is_null()) return null;
		return found;
	}
	return null;
}

<*
 The member `key` of `obj`, which must be present and not null.

 @return? error::INVALID_ARGUMENT : "The member is missing, null, or the parent is not an object"
*>
fn Object*? required(Object* obj, String key)
{
	Object* value = present(obj, key)!;
	if (!value) return wrong_member(key, "is missing")~;
	return value;
}

<*
 A JSON number as an integer. Integral floats are accepted; fractions,
 non-finite values and anything outside the `long` range are refused.

 @return? error::INVALID_ARGUMENT : "The value is not an integer"
 @return? error::OUT_OF_RANGE : "The value does not fit in a long"
*>
fn long? integer_value(Object* value, String key)
{
	if (value.is_int())
	{
		if (value.i > long::max || value.i < long::min) return error::raise(error::OUT_OF_RANGE, error::Domain.INTERNAL, 0, "member '%s' does not fit in 64 bits", key)~;
		return (long)value.i;
	}
	if (!value.is_float()) return wrong_member(key, "is not a number")~;
	double f = value.f;
	if (math::is_nan(f) || math::is_inf(f)) return wrong_member(key, "is not finite")~;
	if (f < (double)long::min || f >= (double)long::max) return error::raise(error::OUT_OF_RANGE, error::Domain.INTERNAL, 0, "member '%s' does not fit in 64 bits", key)~;
	long truncated = (long)f;
	if ((double)truncated != f) return wrong_member(key, "is not an integer")~;
	return truncated;
}

<* The member `key` as a string. @return? error::INVALID_ARGUMENT : "Missing, null, or not a string" *>
fn String? get_string(Object* obj, String key)
{
	Object* value = required(obj, key)!;
	if (!value.is_string()) return wrong_member(key, "is not a string")~;
	return value.s;
}

<* The member `key` as an integer, integral floats accepted. @return? error::INVALID_ARGUMENT, error::OUT_OF_RANGE : "Missing, not an integer, or out of range" *>
fn long? get_int(Object* obj, String key)
{
	Object* value = required(obj, key)!;
	return integer_value(value, key);
}

<* The member `key` as a boolean. @return? error::INVALID_ARGUMENT : "Missing, null, or not a boolean" *>
fn bool? get_bool(Object* obj, String key)
{
	Object* value = required(obj, key)!;
	if (!value.is_bool()) return wrong_member(key, "is not a boolean")~;
	return value.b;
}

<* The member `key` as a double. Integers are widened. @return? error::INVALID_ARGUMENT : "Missing or not a number" *>
fn double? get_double(Object* obj, String key)
{
	Object* value = required(obj, key)!;
	if (value.is_float()) return value.f;
	if (value.is_int()) return (double)value.i;
	return wrong_member(key, "is not a number")~;
}

<* The member `key` as an object. @return? error::INVALID_ARGUMENT : "Missing, null, or not an object" *>
fn Object*? get_object(Object* obj, String key)
{
	Object* value = required(obj, key)!;
	if (!value.is_map()) return wrong_member(key, "is not an object")~;
	return value;
}

<* The member `key` as an array. @return? error::INVALID_ARGUMENT : "Missing, null, or not an array" *>
fn Object*? get_array(Object* obj, String key)
{
	Object* value = required(obj, key)!;
	if (!value.is_array()) return wrong_member(key, "is not an array")~;
	return value;
}

<*
 The parameters of a request: an object whose members the method reads. A
 request without parameters has an empty `Params`, so every optional read gets
 its default and every required read names the missing member.
*>
struct Params
{
	Object* object; // the params object; null when the request had none
}

<* The required string member `key`. @return? error::INVALID_ARGUMENT : "Missing, null, or not a string" *>
fn String? Params.string(self, String key) => get_string(self.object, key);

<* The required integer member `key`, integral floats accepted. @return? error::INVALID_ARGUMENT, error::OUT_OF_RANGE : "Missing or not an integer" *>
fn long? Params.integer(self, String key) => get_int(self.object, key);

<* The required boolean member `key`. @return? error::INVALID_ARGUMENT : "Missing or not a boolean" *>
fn bool? Params.boolean(self, String key) => get_bool(self.object, key);

<* The required numeric member `key`. @return? error::INVALID_ARGUMENT : "Missing or not a number" *>
fn double? Params.number(self, String key) => get_double(self.object, key);

<*
 The string member `key` when present; empty when it is absent or null. A
 member of another type is still an error.

 @return? error::INVALID_ARGUMENT : "The member is not a string"
*>
fn Maybe{String}? Params.optional_string(self, String key)
{
	Object* value = present(self.object, key)!;
	if (!value) return {};
	if (!value.is_string()) return wrong_member(key, "is not a string")~;
	return maybe::value{String}(value.s);
}

<*
 The integer member `key`, or `fallback` when it is absent or null.

 @param fallback : "The value when the member is absent"
 @return? error::INVALID_ARGUMENT, error::OUT_OF_RANGE : "The member is present and is not an integer"
*>
fn long? Params.int_or(self, String key, long fallback)
{
	Object* value = present(self.object, key)!;
	if (!value) return fallback;
	return integer_value(value, key);
}
