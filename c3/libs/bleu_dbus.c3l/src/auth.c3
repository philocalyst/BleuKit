<*
 SASL authentication for the D-Bus transport: the text protocol that runs
 before any message is sent (spec "Authentication Protocol").

 Only the EXTERNAL mechanism is used. The client sends its real user id, which
 the kernel verifies with SO_PEERCRED on the Unix socket, and then negotiates
 descriptor passing. This module formats the commands and parses the replies;
 the connection performs the I/O.

 Sources: D-Bus specification, "Authentication Protocol", "EXTERNAL" (the
 example "AUTH EXTERNAL 31303030" for uid 1000), and "NEGOTIATE_UNIX_FD". The
 hex encoding of the uid is the ASCII decimal digits, as in the specification's
 example; sd-bus src/libsystemd/sd-bus/bus-auth.c (auth_external) does the same.
*>
module bleu::dbus::auth;
import bleu::error;

<* Line terminator of every command and reply. *>
const LINE_END = "\r\n";

<* The mechanism this client uses. *>
const MECHANISM = "EXTERNAL";

<* Kinds of server reply the client acts on. *>
enum ReplyKind : char
{
	OK,            // authenticated; argument is the server GUID
	REJECTED,      // mechanism refused; argument lists the mechanisms offered
	AGREE_UNIX_FD, // descriptor passing agreed
	ERROR,         // the server did not understand the command
	DATA,          // a challenge: not used by EXTERNAL, so an error here
	OTHER,         // anything else
}

<* One reply line, split into its command and argument. *>
struct Reply
{
	ReplyKind kind;
	String argument;
}

<*
 The AUTH command for EXTERNAL with the decimal user id as the identity, hex
 encoded: "AUTH EXTERNAL 31303030" for uid 1000.

 @param out : "Buffer the line is appended to"
*>
fn void format_external(DString* out, uint uid)
{
	out.append_string("AUTH ");
	out.append_string(MECHANISM);
	out.append_char(' ');
	DString digits;
	digits.init(tmem);
	digits.appendf("%d", (long)uid)!!;
	foreach (c : digits.str_view())
	{
		out.append_char(hex_digit(c >> 4));
		out.append_char(hex_digit(c & 0x0F));
	}
	out.append_string(LINE_END);
}

<* The NEGOTIATE_UNIX_FD command line. *>
fn void format_negotiate_unix_fd(DString* out)
{
	out.append_string("NEGOTIATE_UNIX_FD");
	out.append_string(LINE_END);
}

<* The BEGIN command line, after which only D-Bus messages are exchanged. *>
fn void format_begin(DString* out)
{
	out.append_string("BEGIN");
	out.append_string(LINE_END);
}

<*
 Index of the first `\r\n` in `buffer`, which ends the first complete line.

 @return? NOT_FOUND : "No complete line is buffered yet"
*>
fn usz? find_line_end(String buffer)
{
	for (usz i = 0; i + 1 < buffer.len; i++)
	{
		if (buffer[i] == '\r' && buffer[i + 1] == '\n') return i;
	}
	return NOT_FOUND~;
}

<*
 Parse one reply line, without its terminator.

 @param line : "A line such as \"OK 0123...\" or \"REJECTED EXTERNAL\""
 @return? error::PROTOCOL : "The line is empty or is not ASCII"
*>
fn Reply? parse_reply(String line)
{
	if (line.len == 0) return error::PROTOCOL~;
	foreach (c : line)
	{
		if (c >= 0x80) return error::PROTOCOL~;
	}
	usz space = line.len;
	for (usz i = 0; i < line.len; i++)
	{
		if (line[i] == ' ')
		{
			space = i;
			break;
		}
	}
	String command  = line[0:space];
	String argument = space < line.len ? line[space + 1:line.len - space - 1] : "";
	if (command == "OK") return { .kind = OK, .argument = argument };
	if (command == "REJECTED") return { .kind = REJECTED, .argument = argument };
	if (command == "AGREE_UNIX_FD") return { .kind = AGREE_UNIX_FD, .argument = argument };
	if (command == "ERROR") return { .kind = ERROR, .argument = argument };
	if (command == "DATA") return { .kind = DATA, .argument = argument };
	return { .kind = OTHER, .argument = argument };
}

// Lower-case hex digit for the low nibble of `n`.
fn char hex_digit(char n) @inline => (char)("0123456789abcdef"[n & 0x0F]);