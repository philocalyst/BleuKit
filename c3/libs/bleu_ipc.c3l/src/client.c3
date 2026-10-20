<*
 A client of the IPC protocol: connects to a server, makes requests, and reads
 subscription frames. Used by the tests and by `bleuctl`.

 A client holds one connection and is not thread-safe: one thread uses it at a
 time. Replies are matched to requests by id. Lines that arrive while a request
 waits (subscription frames, replies to other requests) are kept in order and
 returned by `next_line`.

 The client must not move in memory after `connect`: its poller refers to its
 wake-up.
*>
module bleu::ipc::client @feat(POSIX);
import std::collections::list, std::encoding::json, std::collections::object, std::time, bleu::error, bleu::deadline, bleu::rt::poller, bleu::rt::wakeup, bleu::rt::unix, bleu::ipc::wire, bleu::ipc::line;

<* Poller tag of the connection's socket. *>
const usz SOCKET_TAG = 1;

<*
 A connection to a server. Create with `connect`, release with `free`.
*>
struct Client
{
	Allocator allocator;
	unix::UnixSocket socket;
	wakeup::Wakeup wake;
	poller::Poller waiter;
	line::LineBuffer input;
	// Heap copies of lines read but not yet returned, oldest first.
	List{String} stash;
	long next_id;
	// The protocol version the server reported in its handshake.
	int api_version;
	// The handshake line as the server sent it, without its newline.
	String handshake;
}

<*
 Connect to the server at `path` and read its handshake.

 @param allocator : "Allocator for the client's buffers and the lines it returns"
 @param timeout : "How long the handshake may take"
 @return? TIMEOUT : "The server did not send its handshake in time"
 @return? error::UNAVAILABLE, NOT_FOUND, error::BACKEND_FAILURE : "The socket could not be connected"
 @return? error::PROTOCOL : "The first line is not a handshake"
*>
fn void? Client.connect(&self, Allocator allocator, String path, Duration timeout)
{
	self.allocator = allocator;
	self.wake.init()!;
	if (catch err = self.open(path, timeout))
	{
		self.free();
		return err~;
	}
}

// The part of `connect` that needs the wake-up open. The caller frees on failure.
fn void? Client.open(&self, String path, Duration timeout)
{
	self.waiter.init(self.allocator, &self.wake, 2)!;
	self.socket = unix::connect(path, unix::SocketKind.STREAM)!;
	self.waiter.add({ .handle = self.socket.fd.raw(), .interest = readable_interest(), .tag = SOCKET_TAG })!;
	self.input.init(self.allocator, wire::DEFAULT_MAX_LINE);
	self.stash.init(self.allocator, 4);
	Deadline limit = deadline::after(timeout);
	String hello   = self.wait_line(limit)!;
	self.handshake = hello.copy(self.allocator);
	DynamicArenaAllocator arena;
	arena.init(self.allocator, 1024);
	defer arena.free();
	Object*? parsed = json::parse(&arena, hello, json::JsonFlavor.JSON);
	if (catch err = parsed)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "server did not send a handshake")~;
	}
	Object* root = parsed;
	if (try version = root.get_int("apiVersion"))
	{
		self.api_version = version;
	}
	else
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "handshake has no apiVersion")~;
	}
}

// Poller interest for the socket: readable only.
fn poller::Interest readable_interest() @private
{
	poller::Interest interest;
	interest.readable = true;
	return interest;
}

<*
 Release the connection and everything the client holds. Safe after a failed
 `connect`.
*>
fn void Client.free(&self)
{
	if (!self.wake.is_open)
	{
		*self = { };
		return;
	}
	if (self.stash.is_initialized())
	{
		for (sz i = 0; i < self.stash.len(); i++) alloc::free(self.allocator, self.stash.get(i).ptr);
		self.stash.free();
	}
	if (self.input.data.len > 0) self.input.free();
	if (self.handshake.len > 0) alloc::free(self.allocator, self.handshake.ptr);
	if (self.waiter.sources.len > 0) self.waiter.free();
	if (self.socket.fd.is_open()) self.socket.close();
	self.wake.close();
	*self = { };
}

<*
 The next line the server sent. Lines that arrived while a request was waiting
 come first, in order. The line is a copy owned by the client's allocator; release
 it with `alloc::free(client.allocator, line.ptr)`.

 @return? TIMEOUT : "No line arrived in time"
 @return? error::DISCONNECTED : "The server closed the connection"
*>
fn String? Client.next_line(&self, Duration timeout)
{
	if (try stashed = self.stash.pop_first()) return stashed;
	String view = self.wait_line(deadline::after(timeout))!;
	return view.copy(self.allocator);
}

<*
 Send a request and wait for the reply with its id. Other lines that arrive in the
 meantime are kept for `next_line`. The reply is a copy owned by the client's
 allocator, to be released as `next_line`'s line is.

 @param method : "The method name"
 @param params_json : "The params as one JSON value; `null` or `{}` for none"
 @return "The reply line: a result or an error frame"
 @return? TIMEOUT : "No reply arrived in time"
 @return? error::DISCONNECTED : "The server closed the connection"
*>
fn String? Client.request(&self, String method, String params_json, Duration timeout)
{
	self.next_id++;
	long id      = self.next_id;
	String frame = wire::request_frame(self.allocator, id, method, params_json);
	defer alloc::free(self.allocator, frame.ptr);
	self.socket.send_all((char[])frame)!;
	Deadline limit = deadline::after(timeout);
	while (true)
	{
		String line = self.wait_line(limit)!;
		if (line_id(line) == id) return line.copy(self.allocator);
		self.stash.push(line.copy(self.allocator));
	}
}

<*
 Subscribe to services by name (an empty list means every topic). The server's
 first frame answers the subscription and is consumed here; the snapshots and
 publications follow through `next_line`.

 @return "The subscription id: the `id` of every frame the subscription sends"
 @return? error::PROTOCOL : "The server refused the subscription"
 @return? TIMEOUT, error::DISCONNECTED : "The server did not answer, or closed"
*>
fn long? Client.subscribe(&self, String[] services, Duration timeout)
{
	self.next_id++;
	long id = self.next_id;
	wire::Writer w;
	w.init(self.allocator, 64);
	w.put("{\"services\":[");
	for (sz i = 0; i < services.len; i++)
	{
		if (i > 0) w.put(",");
		w.put("\"");
		w.put_escaped(services[i]);
		w.put("\"");
	}
	w.put("]}");
	String params = w.finish();
	defer alloc::free(self.allocator, params.ptr);
	String frame = wire::request_frame(self.allocator, id, "subscribe", params);
	defer alloc::free(self.allocator, frame.ptr);
	self.socket.send_all((char[])frame)!;
	Deadline limit = deadline::after(timeout);
	while (true)
	{
		String line = self.wait_line(limit)!;
		if (line_id(line) != id)
		{
			self.stash.push(line.copy(self.allocator));
			continue;
		}
		if (line_has_key(line, "error"))
		{
			return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "subscription refused")~;
		}
		return id;
	}
}

// The next complete line, reading from the socket as needed. The view is valid until the next read.
fn String? Client.wait_line(&self, Deadline limit)
{
	while (true)
	{
		String? next = self.input.next_line();
		if (catch err = next)
		{
			if (err != NO_MORE_ELEMENT) return err~;
		}
		else
		{
			return next;
		}
		if (limit.expired()) return error::raise(TIMEOUT, error::Domain.INTERNAL, 0, "no line from the server")~;
		poller::Ready[]? ready = self.waiter.wait(limit.remaining());
		if (catch err = ready) return err~;
		char[] room     = self.input.reserve();
		RecvResult? got = self.socket.recv(room, { });
		if (catch err = got)
		{
			if (err == error::BUSY) continue;
			return err~;
		}
		self.input.commit(got.bytes);
	}
}

// The `id` of a frame, or -1 when it has none (or is not an integer).
fn long line_id(String line) @private
{
	DynamicArenaAllocator arena;
	arena.init(mem, 1024);
	defer arena.free();
	Object*? parsed = json::parse(&arena, line, json::JsonFlavor.JSON);
	if (catch err = parsed) return -1;
	Object* root = parsed;
	if (!root.is_map()) return -1;
	if (try id = root.get_long("id")) return id;
	return -1;
}

// Whether a frame is a JSON object that has this key.
fn bool line_has_key(String line, String key) @private
{
	DynamicArenaAllocator arena;
	arena.init(mem, 1024);
	defer arena.free();
	Object*? parsed = json::parse(&arena, line, json::JsonFlavor.JSON);
	if (catch err = parsed) return false;
	Object* root = parsed;
	return root.is_map() && root.has_key(key);
}