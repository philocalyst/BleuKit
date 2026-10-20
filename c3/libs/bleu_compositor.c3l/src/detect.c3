<*
 Which compositor is running, decided from the environment alone.

 A compositor's socket variable is the evidence that it is running here:
 HYPRLAND_INSTANCE_SIGNATURE (with XDG_RUNTIME_DIR), SWAYSOCK, I3SOCK, NIRI_SOCKET.
 XDG_CURRENT_DESKTOP is consulted only when none of them is set, and then only
 for the names of compositors this library knows (sway, i3, niri, Hyprland,
 river, dwl). Nothing here touches the filesystem: a stale variable is reported
 by `open`, which then fails with the socket it could not reach.
*>
module bleu::compositor;
import std::os::env;

<* Variable naming the running Hyprland instance (its runtime directory name). *>
const String ENV_HYPRLAND_SIGNATURE = "HYPRLAND_INSTANCE_SIGNATURE";
<* Per-user runtime directory; Hyprland's sockets live below it. *>
const String ENV_RUNTIME_DIR = "XDG_RUNTIME_DIR";
<* Absolute path of sway's IPC socket. *>
const String ENV_SWAYSOCK = "SWAYSOCK";
<* Absolute path of i3's IPC socket. *>
const String ENV_I3SOCK = "I3SOCK";
<* Absolute path of niri's IPC socket. *>
const String ENV_NIRI_SOCKET = "NIRI_SOCKET";
<* Colon-separated desktop names, set by the session. *>
const String ENV_DESKTOP = "XDG_CURRENT_DESKTOP";

<* The variables `detect` reads. An empty string means the variable is unset. *>
struct Environment
{
	String hyprland_signature;
	String runtime_dir;
	String sway_socket;
	String i3_socket;
	String niri_socket;
	String desktop;
}

<*
 What `detect` found.

 `socket` is the command socket and `event_socket` the subscription socket;
 they are equal for sway, i3 and niri, and differ for Hyprland. Both are "" when
 the compositor is known but its socket cannot be named. `reason` is a static
 sentence saying which variable decided the answer.
*>
struct Detection
{
	Kind kind;
	String socket;
	String event_socket;
	String reason;
}

<*
 Look at this process's environment and say which compositor runs here.

 Priority: Hyprland, sway, i3, niri, then the desktop hints river and dwl.

 @param allocator : "Long-lived allocator for the socket paths (not tmem)"
 @return "What was found; `kind` is NONE when nothing matches"
*>
fn Detection detect(Allocator allocator)
{
	Environment environment = {
		.hyprland_signature = read_variable(ENV_HYPRLAND_SIGNATURE),
		.runtime_dir = read_variable(ENV_RUNTIME_DIR),
		.sway_socket = read_variable(ENV_SWAYSOCK),
		.i3_socket = read_variable(ENV_I3SOCK),
		.niri_socket = read_variable(ENV_NIRI_SOCKET),
		.desktop = read_variable(ENV_DESKTOP),
	};
	return detect_from(environment, allocator);
}

<*
 The decision of `detect`, on values already read. Pure: it only builds strings.

 @param allocator : "Long-lived allocator for the socket paths (not tmem)"
 @return "What was found; `kind` is NONE when nothing matches"
*>
fn Detection detect_from(Environment environment, Allocator allocator)
{
	if (environment.hyprland_signature.len > 0) return hyprland_detection(environment, allocator);
	if (environment.sway_socket.len > 0)
	{
		String path = environment.sway_socket.copy(allocator);
		return { .kind = SWAY, .socket = path, .event_socket = path, .reason = "SWAYSOCK is set" };
	}
	if (environment.i3_socket.len > 0)
	{
		String path = environment.i3_socket.copy(allocator);
		return { .kind = I3, .socket = path, .event_socket = path, .reason = "I3SOCK is set" };
	}
	if (environment.niri_socket.len > 0)
	{
		String path = environment.niri_socket.copy(allocator);
		return { .kind = NIRI, .socket = path, .event_socket = path, .reason = "NIRI_SOCKET is set" };
	}
	return desktop_detection(environment.desktop);
}

// The Hyprland sockets are "$XDG_RUNTIME_DIR/hypr/$HIS/.socket.sock" (requests)
// and ".socket2.sock" (events). Source: https://wiki.hypr.land/IPC/
fn Detection hyprland_detection(Environment environment, Allocator allocator) @private
{
	if (environment.runtime_dir.len == 0)
	{
		return { .kind = HYPRLAND, .reason = "HYPRLAND_INSTANCE_SIGNATURE is set but XDG_RUNTIME_DIR is not" };
	}
	String base = string::tformat("%s/hypr/%s", environment.runtime_dir, environment.hyprland_signature).copy(allocator);
	return {
		.kind = HYPRLAND,
		.socket = string::tformat("%s/.socket.sock", base).copy(allocator),
		.event_socket = string::tformat("%s/.socket2.sock", base).copy(allocator),
		.reason = "HYPRLAND_INSTANCE_SIGNATURE is set",
	};
}

// Desktop hints. A hint names the compositor but gives no socket, so `socket`
// stays empty and `open` will refuse it with the reason.
fn Detection desktop_detection(String desktop) @private
{
	if (desktop_names(desktop, "sway")) return { .kind = SWAY, .reason = "XDG_CURRENT_DESKTOP names sway but SWAYSOCK is unset" };
	if (desktop_names(desktop, "i3")) return { .kind = I3, .reason = "XDG_CURRENT_DESKTOP names i3 but I3SOCK is unset" };
	if (desktop_names(desktop, "niri")) return { .kind = NIRI, .reason = "XDG_CURRENT_DESKTOP names niri but NIRI_SOCKET is unset" };
	if (desktop_names(desktop, "Hyprland")) return { .kind = HYPRLAND, .reason = "XDG_CURRENT_DESKTOP names Hyprland but HYPRLAND_INSTANCE_SIGNATURE is unset" };
	if (desktop_names(desktop, "river")) return { .kind = RIVER, .reason = "XDG_CURRENT_DESKTOP names river; river has no IPC client here" };
	if (desktop_names(desktop, "dwl")) return { .kind = DWL, .reason = "XDG_CURRENT_DESKTOP names dwl; dwl has no IPC client here" };
	return { .kind = NONE, .reason = "no compositor variable is set" };
}

// True when one of the colon-separated items of `desktop` equals `name` exactly.
fn bool desktop_names(String desktop, String name) @private
{
	Splitter items = desktop.tokenize(":");
	while (try item = items.next())
	{
		if (item == name) return true;
	}
	return false;
}

// The value of a variable, or "" when unset. The result is temporary.
fn String read_variable(String name) @private => env::tget_var(name) ?? "";
