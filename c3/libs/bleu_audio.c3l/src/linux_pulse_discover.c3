<*
 Finding the PulseAudio server and its cookie on Linux.

 Socket, in order: the `server` option; PULSE_SERVER when it names a unix path
 ("unix:/path"; TCP host names are not supported here); then
 $XDG_RUNTIME_DIR/pulse/native (pulsecore/core-util.c:1786-1798, pulse/context.c:678).

 Cookie, in order: the `cookie_file` option; PULSE_COOKIE; $XDG_CONFIG_HOME/pulse/cookie
 or ~/.config/pulse/cookie; ~/.pulse-cookie (pulse/client-conf.c:169-213,
 pulsecore/authkey.c:134-143). When no file exists the cookie is 256 zero bytes,
 which only an server with anonymous authentication accepts.
*>
module bleu::audio::linux_pulse @feat(LINUX);
import std::os::env, std::io::path, bleu::error, bleu::rt::fs, bleu::audio::pulse;

const String ENV_SERVER = "PULSE_SERVER";
const String ENV_COOKIE = "PULSE_COOKIE";
const String ENV_RUNTIME_DIR = "XDG_RUNTIME_DIR";
const String ENV_CONFIG_HOME = "XDG_CONFIG_HOME";
const String UNIX_PREFIX = "unix:";
const String SOCKET_SUFFIX = "pulse/native";
const String COOKIE_SUFFIX = "pulse/cookie";
const String HOME_COOKIE = ".pulse-cookie";

<* The socket path, copied into `allocator`. @return? error::UNAVAILABLE : "no socket path can be found" *>
fn String? server_path(Allocator allocator, String configured)
{
	if (configured.len > 0) return configured.copy(allocator);
	if (try server = env::get_var(tmem, ENV_SERVER))
	{
		if (server.starts_with(UNIX_PREFIX)) return server[UNIX_PREFIX.len : server.len - UNIX_PREFIX.len].copy(allocator);
	}
	if (try runtime = env::get_var(tmem, ENV_RUNTIME_DIR))
	{
		return string::tformat("%s/%s", runtime, SOCKET_SUFFIX).copy(allocator);
	}
	return error::UNAVAILABLE~;
}

<* The cookie file that exists, copied into `allocator`; "" when none does. *>
fn String cookie_path(Allocator allocator, String configured)
{
	if (configured.len > 0) return configured.copy(allocator);
	if (try cookie = env::get_var(tmem, ENV_COOKIE)) return cookie.copy(allocator);
	if (try config = env::get_var(tmem, ENV_CONFIG_HOME))
	{
		String candidate = string::tformat("%s/%s", config, COOKIE_SUFFIX);
		if (path::exists((Path)candidate)) return candidate.copy(allocator);
	}
	if (try home = env::get_home_dir(tmem))
	{
		String candidate = string::tformat("%s/.config/%s", home, COOKIE_SUFFIX);
		if (path::exists((Path)candidate)) return candidate.copy(allocator);
		candidate = string::tformat("%s/%s", home, HOME_COOKIE);
		if (path::exists((Path)candidate)) return candidate.copy(allocator);
	}
	return "";
}

<*
 Read the cookie: exactly pulse::COOKIE_LENGTH bytes, or zeros when there is no file.

 @return? error::PROTOCOL : "the file exists but is not pulse::COOKIE_LENGTH bytes"
 @return? error::PERMISSION_DENIED : "the cookie file cannot be read"
*>
fn void? cookie_bytes(Allocator allocator, String path_name, char[pulse::COOKIE_LENGTH]* out)
{
	mem::set(out, 0, pulse::COOKIE_LENGTH);
	if (path_name.len == 0) return;
	String data = fs::read_file(tmem, path_name)!;
	if (data.len != pulse::COOKIE_LENGTH) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "cookie file %s holds %d bytes, not %d", path_name, data.len, pulse::COOKIE_LENGTH)~;
	mem::copy(out, data.ptr, pulse::COOKIE_LENGTH);
}

<* True when a server socket can be found and exists: the probe of this backend. *>
fn bool socket_exists(Options* options)
{
	@pool()
	{
		String socket = server_path(tmem, options.server) ?? "";
		return socket.len > 0 && path::exists((Path)socket);
	};
}
