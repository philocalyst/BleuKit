<*
 Reflective serialisation of plain-data Bleu state.

 `write` and `to_json` take any value whose type is plain data and produce its
 JSON, with no per-type code. The mapping is decided at compile time, from the
 type alone, so the same struct always has the same wire form. The rules are
 tabulated in the library README. In short:

 - `Maybe{T}`: its value, or `null` when empty. Recognised by its shape (a
 struct of exactly `value` and `has_value`).
 - `typedef`: the underlying type. `Level`, `Gain` are floats; `Duration` and
 `NanoDuration` are integers in microseconds and nanoseconds.
 - `enum`: its name as a string, spelled per `Options.enum_style`.
 - `bitstruct`: an object of booleans, one per bool member.
 - `struct`: an object, one member per field, spelled per `Options.key_style`
 unless a `@tag("json", ...)` says otherwise.
 - `String`: a string. `char[N]`: a string up to the first NUL.
 - `char[]`: base64, because a byte slice is not text.
 - other slices and fixed arrays: arrays.
 - `bool`, integers, floats: as their JSON scalars. NaN and infinities: `null`.
 - pointers, unions and 128-bit integers are a compile error naming the member.

 Member tags, read with `@tag("json", value)`:
 - `"-"`: the member is left out.
 - `"omitempty"`: the member is left out when it is empty (an empty `Maybe`,
 an empty string, slice or text, a zero number or `false`, an enum's first
 value, an empty struct-free array).
 - any other value: the member's exact wire name, not restyled.
*>
module bleu::json;
import bleu::error;
import std::collections::maybe;

<*
 The member tag named `json`, or "" when the member has none. Compile-time.

 @param $member : "A member of a struct, from `$Type::members`"
*>
macro String json_tag($member) @const
{
	$if $member.has_tag("json"):
		return $member.get_tag("json");
	$endif
	return "";
}

<*
 The name a member is written under before the key style applies: its
 `@tag("json")` name when that is a rename, else its declared name. Compile-time.
*>
macro String json_name($member) @const
{
	$if json_renamed($member):
		return json_tag($member);
	$endif
	return $member.name;
}

<* True when a member's `@tag("json")` gives an exact wire name. Compile-time. *>
macro bool json_renamed($member) @const
{
	return json_tag($member) != "" && json_tag($member) != "omitempty" && json_tag($member) != "-";
}

<* True when a member is tagged `omitempty`. Compile-time. *>
macro bool json_omits_empty($member) @const => json_tag($member) == "omitempty";

<*
 True when a member of type `$Type` can be serialised at the level of its own
 kind. Pointers, unions, optionals, functions, interfaces, `any`, faults, `void`
 and integers wider than 64 bits are not. Typedefs are checked when they are
 written, through their underlying type. Compile-time.

 @param $Type : "The member's type"
*>
macro bool is_plain_kind($Type) @const
{
	$switch $Type::kind:
		$case SIGNED_INT:
		$case UNSIGNED_INT:
			return $Type::size <= 8;
		$case POINTER:
		$case UNION:
		$case OPTIONAL:
		$case FAULT:
		$case ANY:
		$case FUNC:
		$case INTERFACE:
		$case TYPEID:
		$case VOID:
			return false;
		$default:
			return true;
	$endswitch
}

<*
 True when `$Type` has the shape of `Maybe{T}`: a struct whose members are
 exactly `value` and `has_value`. Structural, because C3 0.8.5 offers no type
 name to compare against.

 @param $Type : "The type to test"
*>
macro bool is_maybe($Type) @const
{
	$if $Type::members.len != 2:
		return false;
	$endif
	$foreach $member : $Type::members:
		$if $member.name == "has_value":
			return $member.type == bool;
		$endif
	$endforeach
	return false;
}

<*
 Compile-time walk over a type: refuses, with the member path in the error,
 every part that is not plain data. Run once per `write` call site, so the
 generic writer below is only instantiated for types that pass.

 @param $Type : "The type to check"
 @param $path : "Where the type sits, as written in the error: `value.inner.items[]`"
*>
macro check_plain_data($Type, $path) @private
{
	$if !is_plain_kind($Type):
		$error "not plain data at " +++ $path
			+++ ": pointers, unions, optionals, functions, interfaces, any, faults, void and integers wider than 64 bits have no JSON form";
	$endif
	$switch $Type::kind:
		$case STRUCT:
			$foreach $member : $Type::members:
				check_plain_data($member.type, $path +++ "." +++ $member.name);
			$endforeach
		$case BITSTRUCT:
			$foreach $member : $Type::members:
				$if $member.type != bool:
					$error "not plain data at " +++ $path +++ "." +++ $member.name
						+++ ": a bitstruct serialises as an object of booleans, so every field must be a bool";
				$endif
			$endforeach
		$case ARRAY:
		$case VECTOR:
		$case SLICE:
			check_plain_data($Type::inner, $path +++ "[]");
		$case TYPEDEF:
			$if $Type != String:
				check_plain_data($Type::inner, $path);
			$endif
		$case CONSTDEF:
			check_plain_data($Type::inner, $path);
		$default:
		// Scalars and enums have no members to check.
	$endswitch
}

<*
 Serialise a value of type `TypeElement`. Generic over the type: the body is
 instantiated per type, so an unsupported type is a compile error.
*>
fn void? write_value(JsonWriter* writer, Options options, TypeElement value)<TypeElement> @private
{
	$switch TypeElement::kind:
		$case BOOL:
			return writer.put_bool(value);
		$case SIGNED_INT:
			return writer.put_int((long)value);
		$case UNSIGNED_INT:
			return writer.put_uint((ulong)value);
		$case FLOAT:
			$if TypeElement == float:
				return writer.put_float(value);
			$else
				return writer.put_double((double)value);
			$endif
		$case ENUM:
			char[NAME_CAPACITY] scratch;
			return writer.put_string(enum_text(value.description, options.enum_style, scratch[..])!);
		$case BITSTRUCT:
			writer.begin_object()!;
			$foreach $member : TypeElement::members:
				write_member{bool}(writer, options, $member.name, false, false, value.$member)!;
			$endforeach
			return writer.end_object();
		$case STRUCT:
			$if is_maybe(TypeElement):
				if (!value.has_value) return writer.put_null();
				var $Inner = $Typeof(value.value);
				return write_value{$Inner}(writer, options, value.value);
			$else
				writer.begin_object()!;
				$foreach $member : TypeElement::members:
					$if json_tag($member) != "-":
						write_member{$member.type}(
							writer,
							options,
							json_name($member),
							json_renamed($member),
							json_omits_empty($member),
							value.$member
						)!;
					$endif
				$endforeach
				return writer.end_object();
			$endif
		$case ARRAY:
		$case VECTOR:
			$if TypeElement::inner == char:
				usz length = 0;
				while (length < value.len && value[length] != 0) length++;
				return writer.put_string((String)value[0:length]);
			$else
				var $Inner = TypeElement::inner;
				writer.begin_array()!;
				for (sz i = 0; i < value.len; i++)
				{
					write_value{$Inner}(writer, options, value[i])!;
				}
				return writer.end_array();
			$endif
		$case SLICE:
			$if TypeElement::inner == char:
				return writer.put_bytes(value);
			$else
				var $Inner = TypeElement::inner;
				writer.begin_array()!;
				for (sz i = 0; i < value.len; i++)
				{
					write_value{$Inner}(writer, options, value[i])!;
				}
				return writer.end_array();
			$endif
		$case TYPEDEF:
			$if TypeElement == String:
				return writer.put_string(value);
			$else
				var $Inner = TypeElement::inner;
				return write_value{$Inner}(writer, options, ($Inner)value);
			$endif
		$case CONSTDEF:
			var $Inner = TypeElement::inner;
			return write_value{$Inner}(writer, options, ($Inner)value);
		$default:
			// Backstop: check_plain_data has already refused every other kind.
			$error "not plain data: only bool, integers, floats, enums, bitstructs, structs, String, slices, arrays, typedefs and Maybe{T} can be serialised";
	$endswitch
}

<*
 Write one struct member under `name`, unless `omits_empty` and the value is
 empty. A name that is not `renamed` follows the key style.

 @param name : "The member's declared name, or its tag rename"
 @param writer : "The writer receiving the member"
 @return? error::OUT_OF_RANGE, error::INVALID_STATE : "A name is too long for the style, or the writer refused the token"
*>
fn void? write_member(
	JsonWriter* writer,
	Options options,
	String name,
	bool renamed,
	bool omits_empty,
	TypeElement value
)<TypeElement> @private
{
	if (omits_empty && is_empty{TypeElement}(value)) return;
	char[NAME_CAPACITY] scratch;
	String key = name;
	if (!renamed) key = key_text(name, options.key_style, scratch[..])!;
	writer.key(key)!;
	return write_value{TypeElement}(writer, options, value);
}

<*
 True when a value is empty for `omitempty`: an empty `Maybe`, string, slice or
 text; a zero number or `false`; an enum's first value. Other values are never
 empty.
*>
fn bool is_empty(TypeElement value)<TypeElement> @private
{
	$switch TypeElement::kind:
		$case BOOL:
			return !value;
		$case SIGNED_INT:
		$case UNSIGNED_INT:
		$case FLOAT:
			return value == 0;
		$case ENUM:
			return value.ordinal == 0;
		$case ARRAY:
		$case VECTOR:
			$if TypeElement::inner == char:
				return value[0] == 0;
			$else
				return value.len == 0;
			$endif
		$case SLICE:
			return value.len == 0;
		$case STRUCT:
			$if is_maybe(TypeElement):
				return !value.has_value;
			$else
				return false;
			$endif
		$case TYPEDEF:
			$if TypeElement == String:
				return value.len == 0;
			$else
				var $Inner = TypeElement::inner;
				return is_empty{$Inner}(($Inner)value);
			$endif
		$default:
			return false;
	$endswitch
}

<*
 Write `value` as its JSON form into `writer`. The writer's state decides where
 it goes: at the top level, as an array element, or after an object key.

 @param writer : "The writer receiving the value"
 @param options : "Enum and key spelling, see `Options`"
 @require !writer.failed : "The writer is still usable"
 @return? error::INVALID_STATE, error::OUT_OF_RANGE : "The value does not fit the document at this point"
*>
macro void? write(JsonWriter* writer, value, Options options = DEFAULT_OPTIONS)
{
	check_plain_data($Typeof(value), "value");
	return write_value{$Typeof(value)}(writer, options, value);
}

<*
 Serialise `value` to a new JSON string owned by `allocator`.

 #### Example:
 ```
 struct User { String name; uint age; }
 String json = json::to_json(mem, (User){ "Ada", 36 })!;
 ```

 @param allocator : "Owner of the result"
 @param options : "Enum and key spelling, see `Options`"
 @return? error::OUT_OF_RANGE : "The value nests deeper than MAX_DEPTH"
*>
macro String? to_json(Allocator allocator, value, Options options = DEFAULT_OPTIONS)
{
	DString text;
	text.init(allocator);
	defer text.free();
	JsonWriter writer;
	writer.init_dstring(&text);
	write(&writer, value, options)!;
	writer.finish()!;
	return text.copy_str(allocator);
}