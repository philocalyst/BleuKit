<*
 Bus addresses: where the session and system buses listen.

 An address is `transport:key=value,key=value`, and several may be given
 separated by `;`, tried in order. Values escape every byte outside
 `[-0-9A-Za-z_/.*]` as `%` and two hex digits. This module parses addresses
 into the Unix socket endpoints a client can connect to, and finds the session
 and system bus addresses from the environment or their well-known locations.

 Sources: D-Bus specification, "Server Addresses" (escaping, the `;` separator,
 the `unix:` keys, `runtime` being listen-only, "Exactly one of the keys path,
 abstract, runtime, dir or tmpdir must be provided"), "Well-known Message Bus
 Instances" (DBUS_SESSION_BUS_ADDRESS, DBUS_SYSTEM_BUS_ADDRESS, and the system
 socket /var/run/dbus/system_bus_socket). The per-user session socket
 /run/user/<uid>/bus is the XDG runtime directory convention.
*>
module bleu::dbus::address;
import bleu::error, bleu::dbus::transport, std::os::env;
import std::collections::list;

<* Environment variable naming the session bus. *>
const SESSION_BUS_VARIABLE = "DBUS_SESSION_BUS_ADDRESS";

<* Environment variable naming the system bus. *>
const SYSTEM_BUS_VARIABLE = "DBUS_SYSTEM_BUS_ADDRESS";

<* Environment variable that names the per-user runtime directory. *>
const RUNTIME_DIR_VARIABLE = "XDG_RUNTIME_DIR";

<* Well-known socket of the system bus. *>
const SYSTEM_BUS_ADDRESS = "unix:path=/var/run/dbus/system_bus_socket";

<* Session bus address of a user, used when none is configured. Takes the uid. *>
const SESSION_BUS_ADDRESS_FORMAT = "unix:path=/run/user/%d/bus";

<* Session bus address that asks for a bus to be started; it is not supported, so the default is used. *>
const AUTOLAUNCH_PREFIX = "autolaunch:";

<* The only transport name this library connects with. *>
const UNIX_TRANSPORT = "unix";

<* Separator between alternative addresses. *>
const ADDRESS_SEPARATOR = ';';

<* Separator between the key=value pairs of one address. *>
const PAIR_SEPARATOR = ',';

<*
 One Unix socket a client can connect to. `path` is a filesystem path, or an
 abstract name without its leading NUL when `abstract` is set.
*>
struct Endpoint
{
	bool abstract;
	String path;
}

<*
 Parse an address list into the endpoints a client can connect to, in order.
 Entries with transports this library does not implement (tcp, autolaunch,
 launchd ...) are skipped, and so are entries that name only a listen-only
 socket (`dir`, `tmpdir`).

 @param allocator : "Allocator for the endpoints and their unescaped paths"
 @return? error::INVALID_ARGUMENT : "The address is empty or malformed, or no entry is connectable"
 @return? error::UNSUPPORTED : "Every entry uses a transport this library does not implement"
*>
fn Endpoint[]? parse_addresses(Allocator allocator, String addresses)
{
	if (addresses.len == 0) return error::INVALID_ARGUMENT~;
	List{Endpoint} found;
	found.init(tmem);
	bool unsupported = false;
	bool malformed = false;
	usz start = 0;
	while (start <= addresses.len)
	{
		usz end = find_byte(addresses, ADDRESS_SEPARATOR, start);
		if (catch err = parse_entry(allocator, addresses[start:end - start], &found))
		{
			if (err == error::UNSUPPORTED)
			{
				unsupported = true;
			}
			else
			{
				malformed = true;
			}
		}
		start = end + 1;
	}
	if (found.len() > 0) return found.to_aligned_array(allocator);
	if (unsupported && !malformed) return error::UNSUPPORTED~;
	return error::INVALID_ARGUMENT~;
}

<*
 The session bus address: DBUS_SESSION_BUS_ADDRESS when it is set to a real
 address, otherwise the per-user socket.

 @return? error::UNAVAILABLE : "The current user id is unknown"
*>
fn String? session_address(Allocator allocator)
{
	if (try value = env::get_var(allocator, SESSION_BUS_VARIABLE))
	{
		if (value.len > 0 && !value.starts_with(AUTOLAUNCH_PREFIX)) return value;
	}
	uint uid = transport::current_uid()!;
	return string::format(allocator, SESSION_BUS_ADDRESS_FORMAT, (long)uid);
}

<*
 The system bus address: DBUS_SYSTEM_BUS_ADDRESS when it is set, otherwise the
 well-known socket.
*>
fn String system_address(Allocator allocator)
{
	if (try value = env::get_var(allocator, SYSTEM_BUS_VARIABLE))
	{
		if (value.len > 0) return value;
	}
	return SYSTEM_BUS_ADDRESS;
}

// Parses one `transport:key=value,...` entry and appends its endpoint to `found`.
// UNSUPPORTED marks a transport this library does not implement.
fn void? parse_entry(Allocator allocator, String entry, List{Endpoint}* found) @private
{
	usz colon = find_byte(entry, ':', 0);
	if (colon >= entry.len || entry[0:colon] != UNIX_TRANSPORT) return error::UNSUPPORTED~;
	String options = entry[colon + 1:entry.len - colon - 1];
	Endpoint endpoint;
	uint selectors = 0;
	bool listen_only = false;
	usz start = 0;
	while (start <= options.len)
	{
		usz end = find_byte(options, PAIR_SEPARATOR, start);
		String pair = options[start:end - start];
		start = end + 1;
		usz equals = find_byte(pair, '=', 0);
		if (equals >= pair.len) continue; // not key=value: ignored
		String key = pair[0:equals];
		String value = unescape(allocator, pair[equals + 1:pair.len - equals - 1])!;
		switch (key)
		{
			case "path":
				endpoint = { .abstract = false, .path = value };
				selectors++;
			case "abstract":
				if (!env::LINUX) return error::UNSUPPORTED~;
				endpoint = { .abstract = true, .path = value };
				selectors++;
			case "runtime":
				if (value != "yes") return error::INVALID_ARGUMENT~;
				String runtime_dir = env::get_var(allocator, RUNTIME_DIR_VARIABLE)!;
				endpoint = { .abstract = false, .path = string::format(allocator, "%s/bus", runtime_dir) };
				selectors++;
			case "dir":
			case "tmpdir":
				listen_only = true;
				selectors++;
			default:
				// Unknown keys are ignored: the specification reserves them for later use.
		}
	}
	if (selectors != 1 || listen_only || endpoint.path.len == 0) return error::INVALID_ARGUMENT~;
	found.push(endpoint);
}

<*
 Decode `%xx` escapes. An unescaped byte outside the optionally-escaped set, a
 `%` without two hex digits after it, or a non-hex digit is an error.

 @return? error::INVALID_ARGUMENT : "A malformed escape, or an unescaped byte the specification forbids"
*>
fn String? unescape(Allocator allocator, String raw) @private
{
	DString out;
	out.init(tmem);
	usz i = 0;
	while (i < raw.len)
	{
		char c = raw[i];
		if (c != '%')
		{
			if (!is_optionally_escaped(c)) return error::INVALID_ARGUMENT~;
			out.append_char(c);
			i++;
			continue;
		}
		if (raw.len - i < 3) return error::INVALID_ARGUMENT~;
		int high = hex_value(raw[i + 1]);
		int low = hex_value(raw[i + 2]);
		if (high < 0 || low < 0) return error::INVALID_ARGUMENT~;
		out.append_char((char)(high * 16 + low));
		i += 3;
	}
	return out.copy_str(allocator);
}

// Bytes that never need escaping in an address value: [-0-9A-Za-z_/.*].
fn bool is_optionally_escaped(char c) @inline
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
		|| c == '-' || c == '_' || c == '/' || c == '.' || c == '*';
}

// The value of a hex digit, or -1.
fn int hex_value(char c) @inline
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

// Index of the first `c` at or after `from`, or the length of `text` when absent.
fn usz find_byte(String text, char c, usz from) @inline
{
	for (usz i = from; i < text.len; i++)
	{
		if (text[i] == c) return i;
	}
	return text.len;
}
