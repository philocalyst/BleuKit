<*
 The property list value tree: what XML and binary plists decode to, and what
 `app_bundle` reads.

 Source: Apple "Property List Programming Guide" (the eight value types and the
 dictionary and array rules), and CoreFoundation's `CFBinaryPList.c` for the
 binary types. The date type is a CFAbsoluteTime: seconds since
 2001-01-01T00:00:00Z, stored as a double.

 A `Value` is an owned tree. Every string, array and byte run is allocated from
 the allocator the reader was given, so freeing that allocator (for example by
 releasing a `DynamicArenaAllocator`) frees the whole tree. Accessors return
 `NOT_FOUND` when the key or index is absent or the value has another kind.
*>
module bleu::plist::value;
import bleu::error, std::collections::list, std::collections::set;

const long UNIX_TO_CF_EPOCH_SECONDS    = 978307200;
const long SECONDS_PER_DAY             = 86400;
const long SECONDS_PER_HOUR            = 3600;
const long SECONDS_PER_MINUTE          = 60;
const long DAYS_FROM_CIVIL_EPOCH_SHIFT = 719468;
const long DAYS_PER_ERA                = 146097;
const long YEARS_PER_ERA               = 400;
const int DATE_LENGTH                  = 20;
const int MONTHS_PER_YEAR              = 12;
<* Deepest container nesting the readers accept; deeper input is refused, not followed. *>
const int MAX_NESTING                  = 512;

<* The eight types a property list can hold. *>
enum Kind : char
{
	DICT,
	ARRAY,
	STRING,
	INTEGER,
	REAL,
	BOOL,
	DATE,
	DATA,
	UID,
}

<*
 One `key` and `value` of a dictionary. Members keep the order of the file.
*>
struct Member
{
	String key;
	Value value;
}

<*
 A property list value. Only the field named by `kind` is meaningful.
*>
struct Value
{
	Kind kind;
	bool boolean; // BOOL
	long integer; // INTEGER, and the value of UID
	double real; // REAL
	double date; // DATE: seconds since 2001-01-01T00:00:00Z
	String text; // STRING
	char[] bytes; // DATA
	Value[] items; // ARRAY
	Member[] members; // DICT
}

<* Whether `value` is of `kind`. *>
fn bool Value.is(&self, Kind kind) @inline => self.kind == kind;

<*
 The member of a dictionary with this key.

 @return? NOT_FOUND : "This is not a dictionary, or it has no such key"
*>
fn Value*? Value.get(&self, String key)
{
	if (self.kind != DICT) return NOT_FOUND~;
	foreach (&member : self.members)
	{
		if (member.key == key) return &member.value;
	}
	return NOT_FOUND~;
}

<*
 The element of an array at `index`.

 @return? NOT_FOUND : "This is not an array, or the index is out of range"
*>
fn Value*? Value.element(&self, usz index)
{
	if (self.kind != ARRAY || index >= self.items.len) return NOT_FOUND~;
	return &self.items[index];
}

<* The text of a STRING. *>
fn String? Value.as_string(&self) @inline
{
	if (self.kind != STRING) return NOT_FOUND~;
	return self.text;
}

<* The number of an INTEGER (or the value of a UID). *>
fn long? Value.as_integer(&self) @inline
{
	if (self.kind != INTEGER && self.kind != UID) return NOT_FOUND~;
	return self.integer;
}

<* The number of a REAL. *>
fn double? Value.as_real(&self) @inline
{
	if (self.kind != REAL) return NOT_FOUND~;
	return self.real;
}

<* The truth of a BOOL. *>
fn bool? Value.as_bool(&self) @inline
{
	if (self.kind != BOOL) return NOT_FOUND~;
	return self.boolean;
}

<* The CFAbsoluteTime of a DATE. *>
fn double? Value.as_date(&self) @inline
{
	if (self.kind != DATE) return NOT_FOUND~;
	return self.date;
}

<* The bytes of a DATA value. *>
fn char[]? Value.as_data(&self) @inline
{
	if (self.kind != DATA) return NOT_FOUND~;
	return self.bytes;
}

<*
 Parse an XML plist `<date>`, which is ISO 8601 in the form `YYYY-MM-DDTHH:MM:SSZ`
 (UTC, whole seconds), into a CFAbsoluteTime.

 @return? error::PROTOCOL : "The text is not in that form, or a field is out of range"
*>
fn double? parse_date(String text)
{
	if (text.len != DATE_LENGTH || text[4] != '-' || text[7] != '-' || text[10] != 'T' || text[13] != ':'
		|| text[16] != ':'
		|| text[19] != 'Z')
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "date '%s' is not YYYY-MM-DDTHH:MM:SSZ", text)~;
	}
	long year   = digits(text[0:4])!;
	long month  = digits(text[5:2])!;
	long day    = digits(text[8:2])!;
	long hour   = digits(text[11:2])!;
	long minute = digits(text[14:2])!;
	long second = digits(text[17:2])!;
	if (year < 1 || month < 1 || month > MONTHS_PER_YEAR || day < 1 || day > days_in_month(
		year,
		month
	) || hour > 23 || minute > 59 || second > 59)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "date '%s' has a field out of range", text)~;
	}
	long days = days_from_civil(year, month, day);
	return (double)(days * SECONDS_PER_DAY + hour * SECONDS_PER_HOUR + minute * SECONDS_PER_MINUTE + second
		- UNIX_TO_CF_EPOCH_SECONDS);
}

<*
 Format a CFAbsoluteTime as an XML plist `<date>`. Fractions of a second are
 dropped, because the XML form has whole seconds only.

 @param [&inout] allocator : "Allocator for the text"
*>
fn String format_date(Allocator allocator, double seconds)
{
	long unix = (long)seconds + UNIX_TO_CF_EPOCH_SECONDS;
	long days = unix / SECONDS_PER_DAY;
	long rest = unix % SECONDS_PER_DAY;
	if (rest < 0)
	{
		rest += SECONDS_PER_DAY;
		days--;
	}
	CivilDate date = civil_from_days(days);
	return string::tformat(
		"%04d-%02d-%02dT%02d:%02d:%02dZ",
		date.year,
		date.month,
		date.day,
		rest / SECONDS_PER_HOUR,
		(rest % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE,
		rest % SECONDS_PER_MINUTE
	)
		.copy(allocator);
}

<*
 Add a member to a dictionary being built, refusing a key that is already there.
 A property list dictionary has unique keys.

 @param [&inout] keys : "Every key added so far to this dictionary"
 @return? error::PROTOCOL : "The key is a duplicate"
*>
fn void? add_member(List{Member}* members, HashSet{String}* keys, String key, Value value)
{
	if (!keys.add(
		key
	)) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "duplicate dictionary key '%s'", key)~;
	members.push({ .key = key, .value = value });
}

// A calendar date.
struct CivilDate
{
	long year;
	long month;
	long day;
}

// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
fn long days_from_civil(long year, long month, long day) @local
{
	long y             = month <= 2 ? year - 1 : year;
	long era           = (y >= 0 ? y : y - (YEARS_PER_ERA - 1)) / YEARS_PER_ERA;
	long year_of_era   = y - era * YEARS_PER_ERA;
	long shifted_month = month > 2 ? month - 3 : month + 9;
	long day_of_year   = (153 * shifted_month + 2) / 5 + day - 1;
	long day_of_era    = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
	return era * DAYS_PER_ERA + day_of_era - DAYS_FROM_CIVIL_EPOCH_SHIFT;
}

// The inverse of `days_from_civil`.
fn CivilDate civil_from_days(long days) @local
{
	long z           = days + DAYS_FROM_CIVIL_EPOCH_SHIFT;
	long era         = (z >= 0 ? z : z - (DAYS_PER_ERA - 1)) / DAYS_PER_ERA;
	long day_of_era  = z - era * DAYS_PER_ERA;
	long year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365;
	long day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
	long shifted     = (5 * day_of_year + 2) / 153;
	long day         = day_of_year - (153 * shifted + 2) / 5 + 1;
	long month       = shifted < 10 ? shifted + 3 : shifted - 9;
	long year        = year_of_era + era * YEARS_PER_ERA + (month <= 2 ? 1 : 0);
	return { .year = year, .month = month, .day = day };
}

fn long days_in_month(long year, long month) @local
{
	if (month == 2)
	{
		bool leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
		return leap ? 29 : 28;
	}
	return month == 4 || month == 6 || month == 9 || month == 11 ? 30 : 31;
}

// A fixed-width run of ASCII decimal digits.
fn long? digits(String text) @local
{
	long result = 0;
	foreach (c : text)
	{
		if (c < '0' || c > '9') return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			0,
			"date field '%s' is not numeric",
			text
		)~;
		result = result * 10 + (long)(c - '0');
	}
	return result;
}

<*
 A stable one-line text form of a tree: dictionaries as `{"key":value,...}` in
 file order, arrays as `[...]`, strings as `s"..."` (with `\\`, `\"` and `\u{hex}`
 for anything outside printable ASCII), integers as `i<n>`, reals and dates as
 `r`/`d` followed by the 16 hex digits of their IEEE-754 bits, data as `x<hex>`,
 booleans as `true`/`false`, and UIDs as `u<n>`. The golden tests compare these
 strings with the output of Python's `plistlib`; it is also useful in logs.

 @param [&inout] allocator : "Allocator for the text"
*>
fn String canonical(Allocator allocator, Value* root)
{
	DString out;
	out.init(tmem);
	write_canonical(&out, root);
	return out.copy_str(allocator);
}

fn void write_canonical(DString* out, Value* node) @local
{
	switch (node.kind)
	{
		case DICT:
			out.append_char('{');
			foreach (i, &member : node.members)
			{
				if (i > 0) out.append_char(',');
				write_quoted(out, member.key);
				out.append_char(':');
				write_canonical(out, &member.value);
			}
			out.append_char('}');
		case ARRAY:
			out.append_char('[');
			foreach (i, &item : node.items)
			{
				if (i > 0) out.append_char(',');
				write_canonical(out, item);
			}
			out.append_char(']');
		case STRING:
			out.append_char('s');
			write_quoted(out, node.text);
		case INTEGER:
			out.append_string(string::tformat("i%d", node.integer));
		case REAL:
			out.append_string(string::tformat("r%016x", bitcast(node.real, ulong)));
		case DATE:
			out.append_string(string::tformat("d%016x", bitcast(node.date, ulong)));
		case DATA:
			out.append_char('x');
			foreach (byte : node.bytes) out.append_string(string::tformat("%02x", (uint)(byte & 0xFF)));
		case BOOL:
			out.append_string(node.boolean ? "true" : "false");
		case UID:
			out.append_string(string::tformat("u%d", node.integer));
	}
}

fn void write_quoted(DString* out, String text) @local
{
	out.append_char('"');
	Char32[] code_points = text.to_temp_utf32()!!;
	foreach (code_point : code_points)
	{
		if (code_point == '\\')
		{
			out.append_string("\\\\");
		}
		else if (code_point == '"')
		{
			out.append_string("\\\"");
		}
		else if (code_point >= 32 && code_point <= 126)
		{
			out.append_char((char)code_point);
		}
		else
		{
			out.append_string(string::tformat("\\u{%x}", code_point));
		}
	}
	out.append_char('"');
}