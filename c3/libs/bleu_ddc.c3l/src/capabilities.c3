<*
 Parser for the MCCS capabilities string, e.g.

     (prot(monitor)type(LCD)model(Wacom One 13)cmds(01 02 03 07 F3)
      vcp(04 05 08 12 14(04 05 06 08 0B) 16 18 1A 60(11 12 0F) AC AE)mccs_ver(2.2))

 Grammar (MCCS 2.2a section 6 and DDC/CI 4.6): a parenthesised list of segments.
 A segment is a name, then a parenthesised value. Values of `vcp` are hex
 codes, each optionally followed by a parenthesised list of allowed values.

 Real monitors break this grammar in ways the parser tolerates and reports:

 * the whole string may lack its outer parentheses (Apple Cinema Display);
 * codes and values may run together (`0203(10 00)0405`), since the Access.bus
   specification allows values without separators;
 * a segment may omit its parentheses (`model LCDPB287`);
 * vendor segments such as `vcpname(...)` are skipped, with their nested
   parentheses balanced;
 * a parenthesis may be missing, which happens when the reply was truncated.
   The codes read so far are kept and the result is `INVALID`.

 The parser never fails: it returns what it understood, and `validity` says how
 much to trust it. A result that is `INVALID` is a reason for the caller to
 read the capabilities again.
*>
module bleu::ddc::capabilities;
import std::collections::list, std::core::mem, std::core::string, bleu::ddc::vcp;

<*
 How much of the capabilities string was understood.

 - VALID: every segment parsed.
 - USABLE: parsed, with something ignored (an invalid code, a bad value, a
   missing `vcp` segment). The codes that are present can be trusted.
 - INVALID: the string is truncated or unbalanced. The codes present were read
   from a damaged string and may be incomplete.
*>
enum Validity : char
{
	VALID,
	USABLE,
	INVALID,
}

<*
 One VCP feature the monitor advertises.

 `values` are the allowed values from the feature's parenthesised list, in the
 order the monitor gives them. It is empty when the monitor gave no list, which
 is typical of continuous features, and `has_values` tells the two cases apart.
*>
struct Feature
{
	VcpCode code;
	bool has_values;
	char[] values;
}

<*
 The parsed capabilities of one monitor. All strings and arrays are allocated
 from the allocator passed to `parse`, and live as long as it does.

 `validity` says how much of the string was understood. `problem` is the first
 thing that was wrong, or empty when `validity` is `VALID`. `model` is the value
 of the `model` segment, `mccs_version` that of `mccs_ver` (such as `2.2`); both
 are empty when absent. `commands` lists the opcodes of `cmds`, in order, and
 `features` the `vcp` features, in order. A repeated code is kept once.
*>
struct Capabilities
{
	Validity validity;
	String problem;
	String model;
	String mccs_version;
	char[] commands;
	Feature[] features;
}

<* Whether the monitor advertises `code` in its `vcp` segment. *>
fn bool Capabilities.supports(&self, VcpCode code)
{
	foreach (&f : self.features)
	{
		if (f.code == code) return true;
	}
	return false;
}

<*
 The allowed values of `code`: empty when the monitor gave no list for it.

 @return? NOT_FOUND : "The monitor does not advertise `code`"
*>
fn char[]? Capabilities.allowed_values(&self, VcpCode code)
{
	foreach (&f : self.features)
	{
		if (f.code == code) return f.values;
	}
	return NOT_FOUND~;
}

// Parsing state. Lives in temporary memory and is turned into a `Capabilities`
// by `finish`.
struct Pending
{
	VcpCode code;
	bool has_values;
	usz first_value;
	usz value_count;
}

struct Parse
{
	Validity validity;
	String problem;
	String model;
	String mccs_version;
	List{char} commands;
	List{Pending} features;
	List{char} values;
	bool has_vcp;
}

// Record a problem: keep the worst validity, and the first message.
fn void Parse.flag(&self, Validity validity, String message)
{
	if (validity > self.validity) self.validity = validity;
	if (self.problem.len == 0) self.problem = message;
}

<*
 Parse a capabilities string.

 @param text : "The string as read from the monitor, with or without NUL padding"
 @param allocator : "Owns the strings and arrays of the result"
*>
fn Capabilities parse(String text, Allocator allocator)
{
	Capabilities result;
	@pool()
	{
		Parse p;
		p.commands.tinit();
		p.features.tinit();
		p.values.tinit();
		String body = text.trim(" \t\r\n\0");
		if (body.len > 0 && body[0] == '(')
		{
			if (body.len >= 2 && body[body.len - 1] == ')')
			{
				body = body[1 : body.len - 2];
			}
			else
			{
				p.flag(INVALID, "capabilities string lacks its closing parenthesis");
				body = body[1 : body.len - 1];
			}
		}
		parse_segments(&p, body);
		if (!p.has_vcp) p.flag(USABLE, "no vcp segment");
		result = finish(&p, allocator);
	};
	return result;
}

// Build the public result from the temporary state.
fn Capabilities finish(Parse* p, Allocator allocator) @private
{
	Feature[] features = alloc::new_array(allocator, Feature, p.features.len());
	char[] all_values = p.values.array_view();
	for (usz i = 0; i < features.len; i++)
	{
		Pending pending = p.features.get((sz)i);
		features[i] = {
			.code = pending.code,
			.has_values = pending.has_values,
			.values = copy_bytes(all_values[pending.first_value : pending.value_count], allocator),
		};
	}
	return {
		.validity = p.validity,
		.problem = p.problem.copy(allocator),
		.model = printable(p.model).copy(allocator),
		.mccs_version = printable(p.mccs_version).copy(allocator),
		.commands = copy_bytes(p.commands.array_view(), allocator),
		.features = features,
	};
}

// Parse the segments of one level, from `text[pos]` to its end.
fn void parse_segments(Parse* p, String text) @private
{
	usz pos = 0;
	while (pos < text.len)
	{
		pos = skip_blanks(text, pos);
		if (pos >= text.len) return;
		usz name_start = pos;
		while (pos < text.len && text[pos] != '(' && text[pos] != ' ') pos++;
		String name = text[name_start : pos - name_start];
		pos = skip_blanks(text, pos);
		if (pos >= text.len)
		{
			p.flag(INVALID, string::tformat("segment '%s' has no value", name));
			return;
		}
		if (text[pos] != '(')
		{
			// Tolerated: a bare value, as in "model LCDPB287".
			usz value_start = pos;
			while (pos < text.len && text[pos] != ' ') pos++;
			p.flag(USABLE, string::tformat("segment '%s' has no parentheses", name));
			segment(p, name, text[value_start : pos - value_start]);
			continue;
		}
		if (name.len == 0)
		{
			p.flag(INVALID, string::tformat("parenthesised value at offset %d has no name", pos));
			pos = matching_paren(text, pos) + 1;
			continue;
		}
		usz close = matching_paren(text, pos);
		String value;
		if (close == text.len)
		{
			p.flag(INVALID, string::tformat("segment '%s' is missing its closing parenthesis", name));
			value = text[pos + 1 : text.len - pos - 1];
			pos = text.len;
		}
		else
		{
			value = text[pos + 1 : close - pos - 1];
			pos = close + 1;
		}
		segment(p, name, value);
	}
}

// Dispatch on the segment name. Unknown (vendor) segments are ignored.
fn void segment(Parse* p, String name, String value) @private
{
	if (is(name, "cmds"))
	{
		parse_commands(p, value);
	}
	else if (is(name, "vcp") || is(name, "VCP"))
	{
		p.has_vcp = true;
		parse_vcp(p, value);
	}
	else if (is(name, "mccs_ver"))
	{
		p.mccs_version = value.trim(" ");
	}
	else if (is(name, "model"))
	{
		p.model = value.trim(" ");
	}
}

// `cmds` values: hex pairs, separated by blanks or run together.
fn void parse_commands(Parse* p, String value) @private
{
	usz pos = 0;
	while (true)
	{
		pos = skip_blanks(value, pos);
		if (pos >= value.len) return;
		usz start = pos;
		while (pos < value.len && value[pos] != ' ') pos++;
		String token = value[start : pos - start];
		if (!add_hex_pairs(token, &p.commands))
		{
			p.flag(USABLE, string::tformat("command token '%s' is not hex pairs", token));
		}
	}
}

// `vcp` values: codes, each optionally followed by a list of allowed values.
fn void parse_vcp(Parse* p, String value) @private
{
	usz pos = 0;
	while (true)
	{
		pos = skip_blanks(value, pos);
		if (pos >= value.len) return;
		usz start = pos;
		while (pos < value.len && value[pos] != ' ' && value[pos] != '(') pos++;
		String token = value[start : pos - start];
		String list;
		bool has_list = pos < value.len && value[pos] == '(';
		if (has_list)
		{
			usz close = matching_paren(value, pos);
			if (close == value.len)
			{
				p.flag(INVALID, string::tformat("values of VCP '%s' are missing their closing parenthesis", token));
				list = value[pos + 1 : value.len - pos - 1];
				pos = value.len;
			}
			else
			{
				list = value[pos + 1 : close - pos - 1];
				pos = close + 1;
			}
		}
		if (token.len == 0 || token.len % 2 != 0 || !all_hex(token))
		{
			p.flag(USABLE, string::tformat("VCP code token '%s' is not hex pairs", token));
			continue;
		}
		// The value list belongs to the last code of a run such as "0203(10 00)".
		usz codes = token.len / 2;
		for (usz i = 0; i < codes; i++)
		{
			bool last = i == codes - 1;
			add_feature(p, (VcpCode)hex_pair(token, 2 * i), has_list && last, list);
		}
	}
}

fn void add_feature(Parse* p, VcpCode code, bool has_list, String list) @private
{
	foreach (&existing : p.features)
	{
		if (existing.code == code)
		{
			p.flag(USABLE, string::tformat("VCP 0x%02x is listed twice", (char)code));
			return;
		}
	}
	usz first = (usz)p.values.len();
	if (has_list) parse_value_list(p, list);
	p.features.push({
		.code = code,
		.has_values = has_list,
		.first_value = first,
		.value_count = (usz)p.values.len() - first,
	});
}

// Values of one feature: hex pairs, blank-separated or run together.
fn void parse_value_list(Parse* p, String list) @private
{
	usz pos = 0;
	while (true)
	{
		pos = skip_blanks(list, pos);
		if (pos >= list.len) return;
		usz start = pos;
		while (pos < list.len && list[pos] != ' ') pos++;
		String token = list[start : pos - start];
		if (!add_hex_pairs(token, &p.values))
		{
			p.flag(USABLE, string::tformat("value token '%s' is not hex pairs", token));
		}
	}
}

// Append the byte of every hex pair in `token`. Returns false, adding nothing, if
// the token is empty, of odd length, or not all hex.
fn bool add_hex_pairs(String token, List{char}* out) @private
{
	if (token.len == 0 || token.len % 2 != 0 || !all_hex(token)) return false;
	for (usz i = 0; i < token.len; i += 2) out.push(hex_pair(token, i));
	return true;
}

// The byte of the two hex digits at `token[at]`. The caller has checked them.
fn char hex_pair(String token, usz at) @private
{
	return (char)(hex_digit(token[at]) * 16 + hex_digit(token[at + 1]));
}

fn bool all_hex(String token) @private
{
	foreach (c : token)
	{
		if (c >= '0' && c <= '9') continue;
		if (c >= 'A' && c <= 'F') continue;
		if (c >= 'a' && c <= 'f') continue;
		return false;
	}
	return true;
}

fn char hex_digit(char c) @private
{
	if (c >= 'a') return (char)(c - 'a' + 10);
	if (c >= 'A') return (char)(c - 'A' + 10);
	return (char)(c - '0');
}

// Index of the parenthesis that closes the one at `open`, or `text.len` if none.
fn usz matching_paren(String text, usz open) @private
{
	usz depth = 0;
	for (usz i = open; i < text.len; i++)
	{
		if (text[i] == '(') depth++;
		if (text[i] == ')')
		{
			depth--;
			if (depth == 0) return i;
		}
	}
	return text.len;
}

fn usz skip_blanks(String text, usz pos) @private
{
	while (pos < text.len && text[pos] == ' ') pos++;
	return pos;
}

fn bool is(String a, String b) @private
{
	return a.len == b.len && mem::equals(a.ptr, b.ptr, a.len);
}

fn char[] copy_bytes(char[] source, Allocator allocator) @private
{
	char[] copy = alloc::new_array(allocator, char, source.len);
	mem::copy(copy.ptr, source.ptr, source.len);
	return copy;
}

// The text without bytes that are not printable ASCII, so that `model` is valid UTF-8.
fn String printable(String text) @private
{
	usz kept = 0;
	char[] buffer = alloc::new_array(tmem, char, text.len);
	foreach (c : text)
	{
		if (c >= 0x20 && c < 0x7F) buffer[kept++] = c;
	}
	return (String)buffer[0 : kept];
}
