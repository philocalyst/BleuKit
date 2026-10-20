<*
 sway and i3 client over the i3-ipc binary protocol. Requests use a connection
 each; the subscription connection stays open and non-blocking. Each request is
 `[con_id=N] <command>` or a bare command for RUN_COMMAND; keyboard layouts use
 `input type:keyboard xkb_switch_layout N` (sway only).

 Commands and criteria were checked against sway's source: `sway/criteria.c`
 (`con_id`), `sway/input/input-manager.c` (`type:` identifiers), and
 `sway/commands/{move,focus,kill,floating,fullscreen,input}.c`.
*>
module bleu::compositor::sway_io @feat(POSIX);
import bleu::rt::unix, bleu::error, bleu::compositor, bleu::compositor::backend, bleu::compositor::sway, bleu::compositor::i3ipc, bleu::compositor::io, bleu::compositor::wire, std::collections::object;

// Event types sway sends on a subscription. i3 has no `input` events.
const String SUBSCRIBE_SWAY = "[\"workspace\",\"window\",\"output\",\"input\"]";
const String SUBSCRIBE_I3 = "[\"workspace\",\"window\",\"output\"]";

<* The state of one sway or i3 connection. The subscription socket is owned here. *>
struct SwayBackend (backend::Backend)
{
	Allocator allocator;
	compositor::Kind flavor;
	String socket_path;
	unix::UnixSocket events;
	wire::Buffer frames;
}

<*
 Subscribe to the events of the compositor `detection` names.

 @param allocator : "Long-lived allocator for the backend (not tmem)"
 @require kind == compositor::Kind.SWAY || kind == compositor::Kind.I3 : "Only sway and i3 use this client"
 @return? error::UNAVAILABLE : "No socket path was found in the environment"
 @return? error::PROTOCOL : "The subscribe reply was not a success"
*>
fn backend::Backend? open(Allocator allocator, compositor::Detection detection, compositor::Kind kind)
{
	if (detection.event_socket.len == 0) return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "%s: %s", kind == compositor::Kind.I3 ? "i3" : "sway", detection.reason)~;
	unix::UnixSocket events = unix::connect(detection.event_socket, unix::SocketKind.STREAM)!;
	wire::Buffer frames;
	frames.init(allocator, io::EVENT_BUFFER_BYTES);
	if (catch err = subscribe(&events, &frames, kind == compositor::Kind.SWAY ? SUBSCRIBE_SWAY : SUBSCRIBE_I3))
	{
		(void)events.close();
		frames.free();
		return err~;
	}
	if (catch err = events.fd.set_nonblocking(true))
	{
		(void)events.close();
		frames.free();
		return err~;
	}
	SwayBackend* self = alloc::new(allocator, SwayBackend);
	self.allocator = allocator;
	self.flavor = kind;
	self.socket_path = detection.socket.copy(allocator);
	self.events = events;
	self.frames = frames;
	return self;
}

// Send SUBSCRIBE and check its `{"success": true}` reply. The reply frame is consumed here.
fn void? subscribe(unix::UnixSocket* socket, wire::Buffer* frames, String types) @private
{
	@pool()
	{
		socket.send_all(i3ipc::encode(tmem, (uint)i3ipc::MessageType.SUBSCRIBE, types))!;
		i3ipc::Frame reply = io::await_frame(socket, frames)!;
		Object* outcome = wire::parse_document(reply.payload, "sway subscribe reply")!;
		if (!wire::flag_member(outcome, "success")) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "subscription was refused")~;
	};
}

// One request on a fresh connection. The reply payload is copied into temporary memory.
fn String? request(String path, uint type, String payload) @private
{
	unix::UnixSocket socket = unix::connect(path, unix::SocketKind.STREAM)!;
	defer (void)socket.close();
	wire::Buffer frames;
	frames.init(mem, io::REPLY_BUFFER_BYTES);
	defer frames.free();
	socket.send_all(i3ipc::encode(tmem, type, payload))!;
	i3ipc::Frame reply = io::await_frame(&socket, &frames)!;
	return reply.payload.copy(tmem);
}

// A request whose reply is JSON. Temporary memory: call inside a `@pool()`.
fn Object*? json_request(String path, uint type, String payload) @private
{
	String text = request(path, type, payload)!;
	return wire::parse_document(text, "sway reply")!;
}

// RUN_COMMAND. The reply is a list with one outcome per command.
fn void? run_command(String path, String command) @private
{
	@pool()
	{
		Object* outcomes = json_request(path, (uint)i3ipc::MessageType.RUN_COMMAND, command)!;
		for (sz i = 0; i < wire::length(outcomes); i++)
		{
			Object* outcome = wire::item(outcomes, i);
			if (wire::flag_member(outcome, "success")) continue;
			return error::raise(error::BACKEND_FAILURE, error::Domain.COMPOSITOR, 0, "sway refused '%s': %s", command, wire::peek(outcome, "error", "no message"))~;
		}
	};
}

fn compositor::Kind SwayBackend.kind(&self) @dynamic => self.flavor;

fn rt::Native SwayBackend.event_handle(&self) @dynamic => self.events.fd.raw();

fn compositor::Model? SwayBackend.snapshot(&self, Allocator allocator) @dynamic
{
	@pool()
	{
		Object* inputs = null;
		if (self.flavor == compositor::Kind.SWAY) inputs = json_request(self.socket_path, (uint)i3ipc::MessageType.GET_INPUTS, "")!;
		sway::Replies replies = {
			.workspaces = json_request(self.socket_path, (uint)i3ipc::MessageType.GET_WORKSPACES, "")!,
			.outputs = json_request(self.socket_path, (uint)i3ipc::MessageType.GET_OUTPUTS, "")!,
			.tree = json_request(self.socket_path, (uint)i3ipc::MessageType.GET_TREE, "")!,
			.inputs = inputs,
		};
		return sway::build(allocator, self.flavor, replies);
	};
}

fn backend::Refresh? SwayBackend.read_events(&self, compositor::Model* model, Allocator allocator) @dynamic
{
	backend::Refresh result = NONE;
	@pool()
	{
		while (io::fill(&self.events, &self.frames)! > 0)
		{
			while (true)
			{
				i3ipc::Frame? frame = i3ipc::take_frame(&self.frames);
				if (catch err = frame)
				{
					if (err != NOT_FOUND) return err~;
					break;
				}
				if (!frame.header.is_event()) continue;
				backend::RawEvent event = { .name = i3ipc::event_name(frame.header.event_type()), .payload = frame.payload };
				result = backend::combine(result, self.apply_event(model, allocator, event));
			}
		}
	};
	return result;
}

fn backend::Refresh SwayBackend.apply_event(&self, compositor::Model* model, Allocator allocator, backend::RawEvent event) @dynamic
{
	return sway::apply(model, allocator, event);
}

fn void? SwayBackend.focus_window(&self, String window_id) @dynamic
{
	if (!wire::is_decimal(window_id)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "not a container id: '%s'", window_id)~;
	return run_command(self.socket_path, string::tformat("[con_id=%s] focus", window_id));
}

fn void? SwayBackend.close_window(&self, String window_id) @dynamic
{
	if (!wire::is_decimal(window_id)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "not a container id: '%s'", window_id)~;
	return run_command(self.socket_path, string::tformat("[con_id=%s] kill", window_id));
}

fn void? SwayBackend.switch_workspace(&self, String id) @dynamic
{
	if (!wire::is_quotable(id)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "workspace name cannot be quoted: '%s'", id)~;
	return run_command(self.socket_path, string::tformat("workspace \"%s\"", id));
}

fn void? SwayBackend.move_window(&self, String window_id, String workspace_id) @dynamic
{
	if (!wire::is_decimal(window_id) || !wire::is_quotable(workspace_id)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "bad container or workspace")~;
	return run_command(self.socket_path, string::tformat("[con_id=%s] move container to workspace \"%s\"", window_id, workspace_id));
}

fn void? SwayBackend.set_layout(&self, uint index) @dynamic
{
	if (self.flavor == compositor::Kind.I3) return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "i3 has no keyboard layout command here")~;
	return run_command(self.socket_path, string::tformat("input type:keyboard xkb_switch_layout %d", index));
}

fn void? SwayBackend.toggle_floating(&self, String window_id) @dynamic
{
	if (!wire::is_decimal(window_id)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "not a container id: '%s'", window_id)~;
	return run_command(self.socket_path, string::tformat("[con_id=%s] floating toggle", window_id));
}

fn void? SwayBackend.toggle_fullscreen(&self, String window_id) @dynamic
{
	if (!wire::is_decimal(window_id)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "not a container id: '%s'", window_id)~;
	return run_command(self.socket_path, string::tformat("[con_id=%s] fullscreen toggle", window_id));
}

fn void SwayBackend.close(&self) @dynamic
{
	(void)self.events.close();
	self.frames.free();
	alloc::free(self.allocator, self);
}
