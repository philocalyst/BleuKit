<*
 JSON reading for the replies of the three protocols. Documents are parsed with
 `std::encoding::json` into temporary memory and read through typed accessors
 that tolerate absent keys and nulls: a missing optional field takes its
 fallback, a missing required array is a PROTOCOL error.
*>
module bleu::compositor::wire;
import std::encoding::json, std::collections::object, std::collections::maybe, bleu::error;

<*
 Parse one complete JSON document. The tree lives in temporary memory: call this
 inside a `@pool()` scope and copy what is kept.

 @param what : "Which reply this is, for the error message"
 @return? error::PROTOCOL : "The text is not one valid JSON document"
*>
fn Object*? parse_document(String text, String what)
{
	Object*? parsed = json::tparse(text);
	if (catch err = parsed) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "%s is not valid JSON", what)~;
	return parsed;
}

<* True when `obj` has a member called `key` (null members count). *>
fn bool has_member(Object* obj, String key) @inline => obj.has_key(key);

<*
 A string member, copied into `allocator`. A missing member, a null or a
 non-string gives `fallback`.
*>
fn String text_member(Object* obj, String key, Allocator allocator, String fallback = "")
{
	String value = obj.get_string(key) ?? fallback;
	return value.copy(allocator);
}

<* An integer member. A missing member, a null or a non-integer gives `fallback`. *>
fn long integer_member(Object* obj, String key, long fallback = 0) => obj.get_long(key) ?? fallback;

<*
 An integer member that may be absent: present when the member is an integer.
*>
fn Maybe{long} optional_integer(Object* obj, String key)
{
	if (try value = obj.get_long(key)) return { .value = value, .has_value = true };
	return {};
}

<*
 A number member that may be written as an integer or a float. Absent when
 neither matches.
*>
fn Maybe{double} number_member(Object* obj, String key)
{
	if (try value = obj.get_float(key)) return { .value = value, .has_value = true };
	if (try whole = obj.get_long(key)) return { .value = (double)whole, .has_value = true };
	return {};
}

<* A boolean member. A missing member, a null or a non-boolean gives `fallback`. *>
fn bool flag_member(Object* obj, String key, bool fallback = false) => obj.get_bool(key) ?? fallback;

<*
 A boolean member that may be absent: present when the member is a boolean.
*>
fn Maybe{bool} optional_flag(Object* obj, String key)
{
	if (try value = obj.get_bool(key)) return { .value = value, .has_value = true };
	return {};
}

<*
 An array member. Absent or not an array is a PROTOCOL error: the protocols
 this library reads always send their lists.

 @return? error::PROTOCOL : "The member is missing or is not an array"
*>
fn Object*? array_member(Object* obj, String key)
{
	Object*? value = obj.get(key);
	if (catch err = value) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "member '%s' is missing", key)~;
	if (!value.is_array()) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "member '%s' is not an array", key)~;
	return value;
}

<*
 An object member. Absent or not an object is a PROTOCOL error.

 @return? error::PROTOCOL : "The member is missing or is not an object"
*>
fn Object*? object_member(Object* obj, String key)
{
	Object*? value = obj.get(key);
	if (catch err = value) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "member '%s' is missing", key)~;
	if (!value.is_map()) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "member '%s' is not an object", key)~;
	return value;
}

<*
 Element `index` of an array: the element is null when the index is out of range
 (callers check `get_len` first).
*>
fn Object* element(Object* list, sz index) @inline => list.get_at(index);

<*
 An integer element of an array, such as one coordinate of a `[x, y]` pair.
 A missing or non-integer element gives `fallback`.
*>
fn long integer_element(Object* list, sz index, long fallback = 0) => list.get_long_at(index) ?? fallback;
