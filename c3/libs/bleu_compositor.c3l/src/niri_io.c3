<*
 niri client: one JSON request line per connection for queries and actions, and a
 persistent connection for the `EventStream`. A reply is read to its newline.

 Source for the wire format: `niri-ipc` 26.4.0 `src/socket.rs` (`send`: one line
 out, one line back; `read_events`: one JSON object per line after the stream
 request) and `src/lib.rs` (the request and reply enums).
*>
module bleu::compositor::niri_io @feat(POSIX);
import bleu::rt::unix, bleu::error, bleu::compositor, bleu::compositor::backend, bleu::compositor::niri, bleu::compositor::io, bleu::compositor::wire, std::collections::object;

<* The state of one niri connection. The event stream is owned here. *>
struct NiriBackend (backend::Backend)
{
	Allocator allocator;
	String socket_path;
	unix::UnixSocket events;
	wire::Buffer lines;
}

<*
 Start the event stream on the socket `detection` names.

 @param allocator : "Long-lived allocator for the backend (not tmem)"
 @return? error::UNAVAILABLE : "No socket path was found in the environment"
 @return? error::BACKEND_FAILURE : "niri refused the EventStream request"
*>
fn backend::Backend? open(Allocator allocator, compositor::Detection detection)
{
	if (detection.event_socket.len == 0) return error::raise(
		error::UNAVAILABLE,
		error::Domain.INTERNAL,
		0,
		"niri: %s",
		detection.reason
	)~;
	unix::UnixSocket events = unix::connect(detection.event_socket, unix::SocketKind.STREAM)!;
	wire::Buffer lines;
	lines.init(allocator, io::EVENT_BUFFER_BYTES);
	if (catch err = start_stream(&events, &lines))
	{
		(void)events.close();
		lines.free();
		return err~;
	}
	if (catch err = events.fd.set_nonblocking(true))
	{
		(void)events.close();
		lines.free();
		return err~;
	}
	NiriBackend* self = alloc::new(allocator, NiriBackend);
	self.allocator = allocator;
	self.socket_path = detection.socket.copy(allocator);
	self.events = events;
	self.lines = lines;
	return self;
}

// Send `EventStream` and check its `Ok` reply. Anything after the reply line stays buffered.
fn void? start_stream(unix::UnixSocket* socket, wire::Buffer* lines) @private
{
	@pool()
	{
		socket.send_all(string::tformat("%s\n", niri::REQUEST_EVENT_STREAM))!;
		String line   = io::await_line(socket, lines, io::REPLY_TIMEOUT)!;
		Object* reply = wire::parse_document(line, "niri EventStream reply")!;
		niri::unwrap(reply, "EventStream")!;
	};
}

// One request line on a fresh connection; returns the reply line (temporary memory).
fn String? request_line(String path, String request) @private
{
	unix::UnixSocket socket = unix::connect(path, unix::SocketKind.STREAM)!;
	defer (void)socket.close();
	wire::Buffer lines;
	lines.init(mem, io::REPLY_BUFFER_BYTES);
	defer lines.free();
	socket.send_all(string::tformat("%s\n", request))!;
	return io::await_line(&socket, &lines, io::REPLY_TIMEOUT);
}

// A query: the reply's `Ok` payload, which is an object holding one member named `key`.
fn Object*? query(String path, String request, String key) @private
{
	String line     = request_line(path, request)!;
	Object* reply   = wire::parse_document(line, request)!;
	Object* payload = niri::unwrap(reply, request)!;
	return wire::member(payload, key);
}

// An action: its reply must be `Ok`.
fn void? action(String path, String request) @private
{
	@pool()
	{
		String line   = request_line(path, request)!;
		Object* reply = wire::parse_document(line, "niri action reply")!;
		niri::unwrap(reply, "action")!;
	};
}

fn compositor::Kind NiriBackend.kind(&self) @dynamic => compositor::Kind.NIRI;

fn rt::Native NiriBackend.event_handle(&self) @dynamic => self.events.fd.raw();

fn compositor::Model? NiriBackend.snapshot(&self, Allocator allocator) @dynamic
{
	@pool()
	{
		niri::Replies replies = {
			.workspaces = query(self.socket_path, niri::REQUEST_WORKSPACES, "Workspaces")!,
			.windows = query(self.socket_path, niri::REQUEST_WINDOWS, "Windows")!,
			.outputs = query(self.socket_path, niri::REQUEST_OUTPUTS, "Outputs")!,
			.layouts = query(self.socket_path, niri::REQUEST_KEYBOARD_LAYOUTS, "KeyboardLayouts")!,
		};
		return niri::build(allocator, replies);
	};
}

fn backend::Refresh? NiriBackend.read_events(&self, compositor::Model* model, Allocator allocator) @dynamic
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
				backend::RawEvent event = niri::parse_event(line)!;
				result = backend::combine(result, self.apply_event(model, allocator, event));
			}
		}
	};
	return result;
}

fn backend::Refresh NiriBackend.apply_event(
	&self,
	compositor::Model* model,
	Allocator allocator,
	backend::RawEvent event
) @dynamic
{
	return niri::apply(model, allocator, event);
}

fn void? NiriBackend.focus_window(&self, String window_id) @dynamic
{
	if (!wire::is_decimal(
		window_id
	)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "not a window id: '%s'", window_id)~;
	return action(self.socket_path, niri::focus_window_request(window_id));
}

fn void? NiriBackend.close_window(&self, String window_id) @dynamic
{
	if (!wire::is_decimal(
		window_id
	)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "not a window id: '%s'", window_id)~;
	return action(self.socket_path, niri::close_window_request(window_id));
}

fn void? NiriBackend.switch_workspace(&self, String id) @dynamic
{
	if (!wire::is_decimal(
		id
	)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "not a workspace id: '%s'", id)~;
	return action(self.socket_path, niri::switch_workspace_request(id));
}

fn void? NiriBackend.move_window(&self, String window_id, String workspace_id) @dynamic
{
	if (!wire::is_decimal(
		window_id
	) || !wire::is_decimal(
		workspace_id
	)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "not a window or workspace id")~;
	return action(self.socket_path, niri::move_window_request(window_id, workspace_id));
}

fn void? NiriBackend.set_layout(&self, uint index) @dynamic
{
	return action(self.socket_path, niri::set_layout_request(index));
}

fn void? NiriBackend.toggle_floating(&self, String window_id) @dynamic
{
	if (!wire::is_decimal(
		window_id
	)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "not a window id: '%s'", window_id)~;
	return action(self.socket_path, niri::toggle_floating_request(window_id));
}

fn void? NiriBackend.toggle_fullscreen(&self, String window_id) @dynamic
{
	if (!wire::is_decimal(
		window_id
	)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "not a window id: '%s'", window_id)~;
	return action(self.socket_path, niri::toggle_fullscreen_request(window_id));
}

fn void NiriBackend.close(&self) @dynamic
{
	(void)self.events.close();
	self.lines.free();
	alloc::free(self.allocator, self);
}