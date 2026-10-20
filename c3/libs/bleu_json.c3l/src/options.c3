<*
 Serialisation options and the spelling of names.

 Two choices are configurable and everything else is fixed by the rules in the
 README. Enum values and member names are spelled by their own style; a
 `@tag("json", ...)` rename bypasses both, because it is an exact wire name.
*>
module bleu::json;
import bleu::error;

<* How an enum value is spelled. The default is `LOWER_SNAKE`. *>
enum EnumStyle : char
{
	LOWER_SNAKE, // "not_charging"
	UPPER_SNAKE, // "NOT_CHARGING", the spelling in the C3 source
}

<* How a struct member name is spelled. The default is `AS_DECLARED`. *>
enum KeyStyle : char
{
	AS_DECLARED, // "time_to_empty", the spelling in the C3 source
	CAMEL_CASE,  // "timeToEmpty"
}

<*
 Serialisation options. The zero value is the default: lower snake case enum
 values and member names exactly as declared.
*>
struct Options
{
	EnumStyle enum_style;
	KeyStyle key_style;
}

<* The default options, for parameter defaults. *>
const Options DEFAULT_OPTIONS = {};

<*
 Longest name written in a non-default style. Member and enum names of Bleu
 state are far shorter; a longer name in `CAMEL_CASE` or `LOWER_SNAKE` is
 refused rather than truncated.
*>
const usz NAME_CAPACITY = 128;

<* Distance between an ASCII lower-case letter and its upper-case form. *>
const char CASE_OFFSET = 'a' - 'A';

<*
 Spell a member name as `CAMEL_CASE`: each underscore that sits between two
 characters is dropped and the character after it is upper-cased, so
 `time_to_empty` becomes `timeToEmpty`. Leading and trailing underscores are
 kept. Other characters, including digits, are copied unchanged.

 @param name : "The declared member name"
 @param scratch : "Storage for the spelled name"
 @return? error::OUT_OF_RANGE : "The name does not fit the scratch storage"
*>
fn String? camel_case(String name, char[] scratch)
{
	sz written = 0;
	bool upper_next = false;
	for (sz i = 0; i < name.len; i++)
	{
		char c = name[i];
		if (c == '_' && i > 0 && i + 1 < name.len)
		{
			upper_next = true;
			continue;
		}
		if (upper_next && c >= 'a' && c <= 'z') c = (char)(c - CASE_OFFSET);
		upper_next = false;
		if (written >= scratch.len) return error::raise(error::OUT_OF_RANGE, error::Domain.INTERNAL, 0, "name '%s' is longer than %d bytes", name, scratch.len)~;
		scratch[written] = c;
		written++;
	}
	return (String)scratch[0:written];
}

<*
 Spell a member name for the given key style. `AS_DECLARED` returns the name
 itself and needs no storage.

 @param scratch : "Storage for the spelled name when the style changes it"
 @return? error::OUT_OF_RANGE : "The name does not fit the scratch storage"
*>
fn String? key_text(String name, KeyStyle style, char[] scratch)
{
	if (style == AS_DECLARED) return name;
	return camel_case(name, scratch);
}

<*
 Spell an enum value name for the given style. `UPPER_SNAKE` returns the name
 itself. `LOWER_SNAKE` lower-cases ASCII letters into the scratch storage.

 @param scratch : "Storage for the spelled name when the style changes it"
 @return? error::OUT_OF_RANGE : "The name does not fit the scratch storage"
*>
fn String? enum_text(String name, EnumStyle style, char[] scratch)
{
	if (style == UPPER_SNAKE) return name;
	if (name.len > scratch.len) return error::raise(error::OUT_OF_RANGE, error::Domain.INTERNAL, 0, "enum value '%s' is longer than %d bytes", name, scratch.len)~;
	for (sz i = 0; i < name.len; i++)
	{
		char c = name[i];
		scratch[i] = c >= 'A' && c <= 'Z' ? (char)(c + CASE_OFFSET) : c;
	}
	return (String)scratch[0:name.len];
}
