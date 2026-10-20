<*
 Names and times shared by the Windows and macOS backends. Pure, with no OS calls,
 so the conversions run and are tested on any platform.
*>
module bleu::secrets::local;
import std::time, bleu::error;

<*
 Namespace prefix of every name this library writes. Credential Manager target
 names and keychain service names begin with it, which is how the search tells
 this library's entries from other applications'.
*>
const NAME_PREFIX    = "bleu:";
<* Separator between service and account in a Credential Manager target name. *>
const char SEPARATOR = ':';
<* Escape introducer: "%25" stands for '%' and "%3A" for the separator. *>
const char ESCAPE    = '%';

<* The Windows FILETIME of the Unix epoch, in 100 ns units (Windows epoch 1601 to 1970). *>
const ulong FILETIME_UNIX_EPOCH      = 116444736000000000;
<* 100 ns units per microsecond. *>
const ulong FILETIME_TICKS_PER_MICRO = 10;

<*
 Escape `text` so that it contains no separator: '%' becomes "%25" and ':' becomes "%3A".
 The result is owned by `allocator`.
*>
fn String escape_part(Allocator allocator, String text)
{
	DString out;
	out.init(tmem);
	foreach (c : text)
	{
		if (c == ESCAPE)
		{
			out.append("%25");
		}
		else if (c == SEPARATOR)
		{
			out.append("%3A");
		}
		else
		{
			out.append_char(c);
		}
	}
	return out.str_view().copy(allocator);
}

<*
 Undo `escape_part`.

 @return? error::PROTOCOL : "A '%' is not followed by 25 or 3A"
*>
fn String? unescape_part(Allocator allocator, String text)
{
	DString out;
	out.init(tmem);
	usz i = 0;
	while (i < text.len)
	{
		char c = text[i];
		if (c != ESCAPE)
		{
			out.append_char(c);
			i++;
			continue;
		}
		if (i + 2 >= text.len) return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			0,
			"truncated escape in a name"
		)~;
		String code = text[i + 1:2];
		if (code == "25")
		{
			out.append_char(ESCAPE);
		}
		else if (code == "3A")
		{
			out.append_char(SEPARATOR);
		}
		else
		{
			return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "unknown escape in a name")~;
		}
		i += 3;
	}
	return out.str_view().copy(allocator);
}

<* The Credential Manager target name for an entry: "bleu:" + escaped service + ":" + escaped account. *>
fn String? target_name(Allocator allocator, String service, String account)
{
	@pool()
	{
		return string::tformat(
			"%s%s%c%s",
			NAME_PREFIX,
			escape_part(tmem, service),
			SEPARATOR,
			escape_part(tmem, account)
		)
			.copy(allocator);
	};
}

<*
 The service and account of a target name written by `target_name`.

 @return? NOT_FOUND : "The name is not one this library wrote"
 @return? error::PROTOCOL : "The name has the prefix but no valid service and account"
*>
fn void? split_target(Allocator allocator, String target, String* service, String* account)
{
	if (!target.starts_with(NAME_PREFIX)) return NOT_FOUND~;
	String body = target[NAME_PREFIX.len:target.len - NAME_PREFIX.len];
	sz at       = body.index_of_char(SEPARATOR) ?? -1;
	if (at < 0) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "a target name has no account part")~;
	*service = unescape_part(allocator, body[0:at])!;
	*account = unescape_part(allocator, body[at + 1:body.len - at - 1])!;
}

<*
 A FILETIME (100 ns units since 1601-01-01 UTC) as a Bleu time (microseconds since the Unix epoch).
 Values before 1970 come out negative.
*>
fn Time filetime_to_time(ulong filetime)
{
	long micros = ((long)filetime - (long)FILETIME_UNIX_EPOCH) / (long)FILETIME_TICKS_PER_MICRO;
	return ((Time)0).add_duration((Duration)micros);
}