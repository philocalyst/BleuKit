<*
 JSON reading for the replies of the three protocols. Documents are parsed with
 `std::encoding::json` into temporary memory, and every read goes through the
 accessors below. They check the JSON type of the value before reading it, so a
 reply of the wrong shape gives a fallback or a PROTOCOL error, never a read of
 the wrong union member.
*>
module bleu::compositor::wire @feat(POSIX);
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
	if (catch err = parsed) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"%s is not valid JSON",
		what
	)~;
	return parsed;
}

<*
 The member `key` of an object.

 @return? NOT_FOUND : "`obj` is not an object, or it has no such member"
*>
fn Object*? member(Object* obj, String key)
{
	if (!obj.is_map()) return NOT_FOUND~;
	return obj.get(key);
}

<*
 True when `obj` is an object with a member `key` whose value is not null.
*>
fn bool present(Object* obj, String key)
{
	Object*? value = member(obj, key);
	if (catch err = value) return false;
	return !value.is_null();
}

<*
 A string member, borrowed: valid as long as `obj`. A missing member, a null or
 a non-string gives `fallback`. Use for comparisons, not for keeping the text.
*>
fn String peek(Object* obj, String key, String fallback = "")
{
	if (!obj.is_map()) return fallback;
	return obj.get_string(key) ?? fallback;
}

<*
 A string member, copied into `allocator`. Fallback rules as in `peek`.
*>
fn String text_member(Object* obj, String key, Allocator allocator, String fallback = "")
{
	return peek(obj, key, fallback).copy(allocator);
}

<* An integer member. A missing member, a null or a non-integer gives `fallback`. *>
fn long integer_member(Object* obj, String key, long fallback = 0)
{
	if (!obj.is_map()) return fallback;
	return obj.get_long(key) ?? fallback;
}

<* An integer member that may be absent: present when the member is an integer. *>
fn Maybe{long} optional_integer(Object* obj, String key)
{
	if (!obj.is_map()) return { };
	if (try value = obj.get_long(key)) return { .value = value, .has_value = true };
	return { };
}

<*
 A number member written as an integer or a float. Absent when neither matches.
*>
fn Maybe{double} number_member(Object* obj, String key)
{
	if (!obj.is_map()) return { };
	if (try value = obj.get_float(key)) return { .value = value, .has_value = true };
	if (try whole = obj.get_long(key)) return { .value = (double)whole, .has_value = true };
	return { };
}

<* A boolean member. A missing member, a null or a non-boolean gives `fallback`. *>
fn bool flag_member(Object* obj, String key, bool fallback = false)
{
	if (!obj.is_map()) return fallback;
	return obj.get_bool(key) ?? fallback;
}

<* A boolean member that may be absent: present when the member is a boolean. *>
fn Maybe{bool} optional_flag(Object* obj, String key)
{
	if (!obj.is_map()) return { };
	if (try value = obj.get_bool(key)) return { .value = value, .has_value = true };
	return { };
}

<*
 An array member. Absent or not an array is a PROTOCOL error: the protocols
 this library reads always send their lists.

 @return? error::PROTOCOL : "The member is missing or is not an array"
*>
fn Object*? array_member(Object* obj, String key)
{
	Object*? value = member(obj, key);
	if (catch err = value) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"member '%s' is missing",
		key
	)~;
	if (!value.is_array()) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"member '%s' is not an array",
		key
	)~;
	return value;
}

<*
 An object member. Absent or not an object is a PROTOCOL error.

 @return? error::PROTOCOL : "The member is missing or is not an object"
*>
fn Object*? object_member(Object* obj, String key)
{
	Object*? value = member(obj, key);
	if (catch err = value) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"member '%s' is missing",
		key
	)~;
	if (!value.is_map()) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"member '%s' is not an object",
		key
	)~;
	return value;
}

<* The number of elements of an array; 0 when `list` is not an array. *>
fn sz length(Object* list)
{
	if (!list.is_array()) return 0;
	return list.get_len();
}

<*
 Element `index` of an array.

 @return? NOT_FOUND : "`list` is not an array, or `index` is out of range"
*>
fn Object*? element(Object* list, sz index)
{
	if (!list.is_array() || index < 0 || index >= list.get_len()) return NOT_FOUND~;
	return list.get_at(index);
}

<*
 An integer element of an array, such as one coordinate of a `[x, y]` pair.
 A missing or non-integer element gives `fallback`.
*>
fn long integer_element(Object* list, sz index, long fallback = 0)
{
	if (!list.is_array()) return fallback;
	return list.get_long_at(index) ?? fallback;
}

<*
 A string element of an array, copied into `allocator`. A missing or non-string
 element gives `fallback`.
*>
fn String text_element(Object* list, sz index, Allocator allocator, String fallback = "")
{
	if (!list.is_array()) return fallback.copy(allocator);
	return (list.get_string_at(index) ?? fallback).copy(allocator);
}

<*
 Element `index` of an array, or null when it is not there. Loops bound by
 `length` never see null.
*>
fn Object* item(Object* list, sz index) => element(list, index) ?? null;