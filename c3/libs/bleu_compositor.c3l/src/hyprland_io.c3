<*
 Hyprland client: the command socket for queries and dispatchers, the event socket
 for `EVENT>>DATA` lines. The command socket is opened for each request, as the
 Hyprland wiki asks (it evaluates connections synchronously; an open connection
 stalls it for five seconds). The event socket stays open and non-blocking.

 Dispatch strings are the legacy `dispatch <name> <args>` form that hyprland-rs
 0.4.0-beta.2 writes (`src/dispatch.rs`); see the backend README for the version
 caveat. Socket paths: `$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/`.
*>
module bleu::compositor::hyprland_io @feat(POSIX);
import bleu::rt, bleu::rt::unix, bleu::error, bleu::compositor, bleu::compositor::backend, bleu::compositor::hyprland, bleu::compositor::io, bleu::compositor::wire, std::collections::object;

<* The state of one Hyprland connection. The event socket is owned here. *>
struct HyprlandBackend (backend::Backend)
{
	Allocator allocator;
	String command_path;
	unix::UnixSocket events;
	wire::Buffer lines;
}

<*
 Connect to the Hyprland instance `detection` names: open the event socket and
 check that the command socket path is reachable.

 @param allocator : "Long-lived allocator for the backend (not tmem)"
 @return? error::UNAVAILABLE : "No socket path was found in the environment"
 @return? error::UNAVAILABLE, error::PERMISSION_DENIED, error::BACKEND_FAILURE : "The event socket could not be opened"
*>
fn backend::Backend? open(Allocator allocator, compositor::Detection detection)
{
	if (detection.event_socket.len == 0) return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "hyprland: %s", detection.reason)~;
	unix::UnixSocket events = unix::connect(detection.event_socket, unix::SocketKind.STREAM)!;
	if (catch err = events.fd.set_nonblocking(true))
	{
		(void)events.close();
		return err~;
	}
	HyprlandBackend* self = alloc::new(allocator, HyprlandBackend);
	self.allocator = allocator;
	self.command_path = detection.socket.copy(allocator);
	self.events = events;
	self.lines.init(allocator, io::EVENT_BUFFER_BYTES);
	return self;
}

// One request on a fresh command connection; the reply is read to end-of-stream.
// Temporary memory: call inside a `@pool()`.
fn String? command(String path, String request) @private
{
	unix::UnixSocket socket = unix::connect(path, unix::SocketKind.STREAM)!;
	defer (void)socket.close();
	socket.send_all(request)!;
	return io::read_to_end(&socket);
}

// A JSON query (`j/...`). Temporary memory: call inside a `@pool()`.
fn Object*? query(String path, String request) @private
{
	String text = command(path, request)!;
	return wire::parse_document(text, request)!;
}

// A dispatcher or keyword. Hyprland answers `ok` on success and an error text otherwise.
fn void? run(String path, String request) @private
{
	@pool()
	{
		String reply = command(path, request)!;
		if (reply.trim() != "ok") return error::raise(error::BACKEND_FAILURE, error::Domain.COMPOSITOR, 0, "hyprland refused '%s': %s", request, reply)~;
	};
}

fn compositor::Kind HyprlandBackend.kind(&self) @dynamic => compositor::Kind.HYPRLAND;

fn rt::Native HyprlandBackend.event_handle(&self) @dynamic => self.events.fd.raw();

fn compositor::Model? HyprlandBackend.snapshot(&self, Allocator allocator) @dynamic
{
	@pool()
	{
		hyprland::Replies replies = {
			.clients = query(self.command_path, "j/clients")!,
			.active = query(self.command_path, "j/activewindow")!,
			.workspaces = query(self.command_path, "j/workspaces")!,
			.monitors = query(self.command_path, "j/monitors")!,
			.devices = query(self.command_path, "j/devices")!,
		};
		return hyprland::build(allocator, replies);
	};
}

fn backend::Refresh? HyprlandBackend.read_events(&self, compositor::Model* model, Allocator allocator) @dynamic
{
	backend::Refresh result = NONE;
	@pool()
	{
		while (io::fill(&self.events, &self.lines)! > 0)
		{
			while (true)
			{
				String? line = self.lines.take_line();
				if (catch err = line)
				{
					if (err != NOT_FOUND) return err~;
					break;
				}
				backend::RawEvent event = hyprland::parse_event(line)!;
				result = backend::combine(result, self.apply_event(model, allocator, event));
			}
		}
	};
	return result;
}

fn backend::Refresh HyprlandBackend.apply_event(&self, compositor::Model* model, Allocator allocator, backend::RawEvent event) @dynamic
{
	return hyprland::apply(model, allocator, event);
}

fn void? HyprlandBackend.focus_window(&self, String window_id) @dynamic
{
	if (!wire::is_token(window_id)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "not a window address: '%s'", window_id)~;
	return run(self.command_path, string::tformat("j/dispatch focuswindow address:%s", window_id));
}

fn void? HyprlandBackend.close_window(&self, String window_id) @dynamic
{
	if (!wire::is_token(window_id)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "not a window address: '%s'", window_id)~;
	return run(self.command_path, string::tformat("j/dispatch closewindow address:%s", window_id));
}

fn void? HyprlandBackend.switch_workspace(&self, String id) @dynamic
{
	if (!wire::is_token(id)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "not a workspace id: '%s'", id)~;
	return run(self.command_path, string::tformat("j/dispatch workspace %s", id));
}

// `movetoworkspace <workspace>,address:<window>`, the form hyprland-rs writes.
fn void? HyprlandBackend.move_window(&self, String window_id, String workspace_id) @dynamic
{
	if (!wire::is_token(window_id) || !wire::is_token(workspace_id)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "bad window or workspace id")~;
	return run(self.command_path, string::tformat("j/dispatch movetoworkspace %s,address:%s", workspace_id, window_id));
}

// `fullscreen` acts on the focused window only, so the window is focused first.
fn void? HyprlandBackend.toggle_fullscreen(&self, String window_id) @dynamic
{
	if (!wire::is_token(window_id)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "not a window address: '%s'", window_id)~;
	run(self.command_path, string::tformat("j/dispatch focuswindow address:%s", window_id))!;
	return run(self.command_path, "j/dispatch fullscreen 0");
}

fn void? HyprlandBackend.toggle_floating(&self, String window_id) @dynamic
{
	if (!wire::is_token(window_id)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "not a window address: '%s'", window_id)~;
	return run(self.command_path, string::tformat("j/dispatch togglefloating address:%s", window_id));
}

// `switchxkblayout <keyboard> <index>` on the main keyboard, read from `j/devices`.
fn void? HyprlandBackend.set_layout(&self, uint index) @dynamic
{
	@pool()
	{
		Object* devices = query(self.command_path, "j/devices")!;
		String keyboard = hyprland::main_keyboard_name(devices, tmem);
		if (keyboard.len == 0) return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "hyprland reports no keyboard")~;
		if (!wire::is_token(keyboard)) return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "keyboard name '%s' has spaces: Hyprland cannot address it", keyboard)~;
		run(self.command_path, string::tformat("switchxkblayout %s %d", keyboard, index))!;
	};
}

fn void HyprlandBackend.close(&self) @dynamic
{
	(void)self.events.close();
	self.lines.free();
	alloc::free(self.allocator, self);
}
