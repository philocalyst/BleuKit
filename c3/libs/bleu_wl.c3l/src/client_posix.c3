<*
 Connecting a client to a compositor on POSIX systems: from an explicit socket path,
 or from the environment as libwayland does (`WAYLAND_SOCKET`, then `WAYLAND_DISPLAY`
 resolved against `XDG_RUNTIME_DIR`).

 Sources: Wayland book, "Wire Protocol" and the environment variables it names
 (https://wayland.freedesktop.org/docs/book/Protocol.html, the "Connecting" section).
*>
module bleu::wl @feat(POSIX);
import bleu::error, bleu::rt, bleu::wl::display, std::os::env, std::core::string;

<* Inherited descriptor, when a parent process passed the socket already connected. *>
const String ENV_WAYLAND_SOCKET = "WAYLAND_SOCKET";

<* Socket name, a bare name resolved against XDG_RUNTIME_DIR or an absolute path. *>
const String ENV_WAYLAND_DISPLAY = "WAYLAND_DISPLAY";

<* Directory of the per-user runtime files. *>
const String ENV_XDG_RUNTIME_DIR = "XDG_RUNTIME_DIR";

<* The socket name used when WAYLAND_DISPLAY is not set. *>
const String DEFAULT_DISPLAY_NAME = "wayland-0";

<* The largest descriptor number accepted from WAYLAND_SOCKET. *>
const int MAX_INHERITED_FD = 0x7FFFFFFF;

<*
 Connect to the socket at `path` and start the client on it.

 @param path : "Filesystem path of the compositor socket"
 @return? NOT_FOUND, error::PERMISSION_DENIED, error::DISCONNECTED, error::BACKEND_FAILURE : "connect(2) failed"
*>
fn void? Client.connect(&self, Allocator allocator, String path)
{
	rt::Native fd = display::native_connect(path)!;
	if (catch err = self.init(allocator, fd))
	{
		display::native_close(fd);
		return err~;
	}
}

<*
 Connect as the environment says. `WAYLAND_SOCKET` names an inherited connected
 descriptor and is used as is. Otherwise `WAYLAND_DISPLAY` (default "wayland-0") is
 used: an absolute path as it is, a bare name under `XDG_RUNTIME_DIR`.

 @return? error::UNAVAILABLE : "XDG_RUNTIME_DIR is not set for a relative socket name"
 @return? error::INVALID_ARGUMENT : "WAYLAND_SOCKET is not a descriptor number"
 @return? NOT_FOUND, error::PERMISSION_DENIED, error::DISCONNECTED, error::BACKEND_FAILURE : "connect(2) failed"
*>
fn void? Client.connect_env(&self, Allocator allocator)
{
	if (try inherited = env::tget_var(ENV_WAYLAND_SOCKET))
	{
		rt::Native fd = parse_descriptor(inherited)!;
		if (catch err = self.init(allocator, fd))
		{
			display::native_close(fd);
			return err~;
		}
		return;
	}
	String name = env::tget_var(ENV_WAYLAND_DISPLAY) ?? DEFAULT_DISPLAY_NAME;
	if (name.len > 0 && name[0] == '/') return self.connect(allocator, name);
	String runtime_dir = env::tget_var(ENV_XDG_RUNTIME_DIR) ?? "";
	if (runtime_dir.len == 0)
	{
		return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "XDG_RUNTIME_DIR is not set")~;
	}
	return self.connect(allocator, string::tformat("%s/%s", runtime_dir, name));
}

// Parse a decimal descriptor number from the environment. Only digits are accepted.
fn rt::Native? parse_descriptor(String text) @private
{
	if (text.len == 0)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "WAYLAND_SOCKET is empty")~;
	}
	int value = 0;
	foreach (c : text)
	{
		if (c < '0' || c > '9' || value > (MAX_INHERITED_FD - 9) / 10)
		{
			return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "WAYLAND_SOCKET is not a descriptor: %s", text)~;
		}
		value = value * 10 + (int)(c - '0');
	}
	return value;
}
