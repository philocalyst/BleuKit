<*
 A connection to a Wayland compositor, below the protocol: the object table, the
 outgoing and incoming byte queues, descriptor passing, and dispatch.

 A `Display` knows nothing about any particular interface. Generated code (see
 `bleu::wl::proto`) supplies each object's `Interface`, which says how to decode its
 events. The one interface the runtime needs by name is `wl_display`, whose `error`
 and `delete_id` events are handled by the generated code calling back into
 `protocol_error` and `release_id` here.

 Threading: a `Display` belongs to one thread. The owner waits on `fd()` with a poller
 (`bleu::rt::poller`), calls `dispatch()` when the descriptor is readable and
 `flush()` when it is writable and `wants_write()` holds, and calls requests in between.

 Object ids follow the wire protocol: the client allocates ids below
 `SERVER_ID_START`, the server allocates the ones from it, and `wl_display.delete_id`
 releases an id for reuse. A destroyed object keeps its id, as a zombie, until the
 server says it is released, because events for it may still be in flight.

 Sources: Wayland book chapter "Wire Protocol"
 (https://wayland.freedesktop.org/docs/book/Protocol.html); wayland.xml `wl_display`
 (the `error` codes at lines 86-97, and `delete_id` at line 101); wayland-backend 0.3.11 src/rs/map.rs (id
 ranges, line 8).
*>
module bleu::wl::display;
import std::collections::list;
import bleu::error, bleu::rt, bleu::wl::wire, std::core::mem;

<* Id of the `wl_display` object, which every connection has from the start. *>
const uint DISPLAY_ID = 1;

<* First id the client may allocate after `wl_display`. *>
const uint FIRST_CLIENT_ID = 2;

<* Ids from here up belong to the server (wayland-backend 0.3.11 src/rs/map.rs:8, SERVER_ID_LIMIT). *>
const uint SERVER_ID_START = 0xFF000000;

<* Bytes of receive buffer. Holds more than one largest message, so a frame never has to wait for space. *>
const usz INBOX_CAPACITY = 4 * wire::MAX_MESSAGE_SIZE;

<* `wl_display.error` codes (wayland.xml, enum wl_display.error). *>
const uint ERROR_NO_MEMORY      = 2;
const uint ERROR_IMPLEMENTATION = 3;

<*
 Decodes one event for a proxy. It reads the arguments from `args`, calls the listener
 of `proxy`, and returns a fault for a malformed message.
*>
alias DispatchFn = fn void?(Display* conn, Proxy* proxy, ushort opcode, wire::Reader* args);

<*
 What the runtime needs to know about an interface: its wire name, the highest
 version this program was generated against, and how its events are decoded.
*>
struct Interface
{
	String name;
	uint version;
	DispatchFn dispatch;
}

<*
 One object of the connection. Generated typed views (`WlOutput` and so on) start with
 a `Proxy`, so a pointer to either converts to the other.

 `zombie` is set once the object was destroyed on this side: its events are then
 decoded, to keep the stream in step, but not delivered. `listener` and `context` are
 set by the generated `set_listener`.
*>
struct Proxy
{
	uint id;
	Interface iface;
	uint version;
	Display* conn;
	void* listener;
	void* context;
	bool zombie;
}

<* A request waiting to be written, with the descriptors it carries (duplicated, owned here). *>
struct Outgoing
{
	char[] bytes;
	usz sent;
	rt::Native[wire::MAX_FDS_PER_MESSAGE] fds;
	usz fd_count;
}

<* What one native receive delivered. *>
struct Received
{
	usz bytes;
	usz fds;
}

<*
 A connection and its state. Create it in place (`adopt`) and do not move it afterwards:
 proxies point back to it.
*>
struct Display
{
	Allocator allocator;
	rt::Native socket;
	bool open;
	bool failed;
	bool nonblocking;
	List{Proxy*} objects;
	List{uint} free_ids;
	uint next_id;
	List{Outgoing} outbox;
	char[] inbox;
	usz inbox_len;
	wire::FdQueue incoming;
}

<*
 Take over a connected socket and create the `wl_display` object. The display owns the
 descriptor from now on and closes it in `close`.

 @param allocator : "Allocator for the object table, the queues and the proxies"
 @param fd : "A connected Wayland socket, already in the state the caller wants"
 @param root : "The interface of `wl_display` (generated as WL_DISPLAY)"
 @return? error::NO_MEMORY : "Allocation failed"
*>
fn void? Display.adopt(&self, Allocator allocator, rt::Native fd, Interface root)
{
	self.allocator = allocator;
	self.socket = fd;
	self.open = true;
	self.failed = false;
	self.nonblocking = false;
	self.objects.init(allocator, 16);
	self.free_ids.init(allocator, 16);
	self.outbox.init(allocator, 16);
	self.inbox = alloc::new_array(allocator, char, (sz)INBOX_CAPACITY);
	self.inbox_len = 0;
	self.incoming = { };
	self.next_id = FIRST_CLIENT_ID;
	self.insert(DISPLAY_ID, root, root.version)!;
}

<*
 Close the descriptor, drop every queued message and descriptor, and free the proxies.
 Proxies must not be used afterwards.
*>
fn void Display.close(&self)
{
	if (!self.open) return;
	self.open = false;
	foreach (&out : self.outbox.array_view()) self.release_outgoing(out);
	while (self.incoming.count > 0) native_close(self.incoming.pop()!!);
	native_close(self.socket);
	foreach (proxy : self.objects.array_view()) alloc::free(self.allocator, proxy);
	self.objects.free();
	self.free_ids.free();
	self.outbox.free();
	alloc::free(self.allocator, self.inbox.ptr);
	self.inbox = { };
}

<* The descriptor the owner waits on with a poller: read-ready for `dispatch`, write-ready for `flush`. *>
fn rt::Native Display.native(&self) @inline => self.socket;

<* Whether the descriptor is in non-blocking mode. *>
fn bool Display.is_nonblocking(&self) @inline => self.nonblocking;

<*
 Switch the descriptor between blocking and non-blocking. A non-blocking display is
 driven by a poller; a blocking one is driven by `Client.roundtrip` and by `dispatch`.

 @return? error::BACKEND_FAILURE : "fcntl(2) failed"
*>
fn void? Display.set_nonblocking(&self, bool non_blocking)
{
	self.require_open()!;
	native_set_nonblocking(self.socket, non_blocking)!;
	self.nonblocking = non_blocking;
}

<* True when at least one request is queued and not yet written. *>
fn bool Display.wants_write(&self) @inline => self.outbox.len() > 0;

<*
 Create a client-side object of `iface` with a fresh id. The version is the lower of
 `version` and the interface's own, as in version negotiation.

 @return? error::OUT_OF_RANGE : "All client ids are in use"
*>
fn Proxy*? Display.new_object(&self, Interface iface, uint version)
{
	self.require_open()!;
	uint id = self.allocate_id()!;
	return self.insert(id, iface, version);
}

<*
 Register an object the server created (an event carried a new_id).

 @return? error::PROTOCOL : "The id is not in the server range, or it is already in use"
*>
fn Proxy*? Display.server_object(&self, uint id, Interface iface, uint version)
{
	if (id < SERVER_ID_START)
	{
		return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			0,
			"server created object %d below the server range",
			id
		)~;
	}
	if (self.find(id) != null)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "server reused object id %d", id)~;
	}
	return self.insert(id, iface, version);
}

<*
 The proxy with this id, or null when the id is unknown or released. A zombie is still
 found: its events arrive until the server releases it.
*>
fn Proxy* Display.find(&self, uint id)
{
	foreach (proxy : self.objects.array_view())
	{
		if (proxy.id == id) return proxy;
	}
	return null;
}

<*
 Mark a proxy destroyed on this side. Its events are still decoded but not delivered,
 and the id is kept until the server sends `wl_display.delete_id`.
*>
fn void Display.retire(&self, Proxy* proxy)
{
	proxy.zombie = true;
	proxy.listener = null;
	proxy.context = null;
}

<*
 The server released this id (`wl_display.delete_id`). The proxy is freed, and a client
 id goes back on the free list. A proxy the server never created is ignored.
*>
fn void Display.release_id(&self, uint id)
{
	foreach (i, proxy : self.objects.array_view())
	{
		if (proxy.id != id) continue;
		self.objects.remove_at((sz)i);
		alloc::free(self.allocator, proxy);
		if (id < SERVER_ID_START) self.free_ids.push(id);
		return;
	}
}

<*
 Queue a request for writing. The descriptors it carries are duplicated, so the caller
 keeps its own; the copies are closed once the message is written. Nothing is written
 here: call `flush`.

 @return? error::INVALID_STATE : "The display is closed or has failed"
 @return? error::BACKEND_FAILURE, error::OUT_OF_RANGE : "A descriptor could not be duplicated"
*>
fn void? Display.send(&self, wire::Writer* writer)
{
	self.require_open()!;
	char[] source = writer.finish();
	char[] copy   = alloc::new_array(self.allocator, char, (sz)source.len);
	mem::copy(copy.ptr, source.ptr, copy.len);
	Outgoing out = { .bytes = copy };
	bool queued  = false;
	defer if (!queued) self.release_outgoing(&out);
	foreach (fd : writer.descriptors())
	{
		out.fds[out.fd_count++] = native_dup(fd)!;
	}
	self.outbox.push(out);
	queued = true;
}

<*
 Write queued messages until the queue is empty or the socket is full. Each message is
 one send, so its descriptors go with its first byte.

 @return "True when everything is written; false when the socket is full (write-ready later)"
 @return? error::DISCONNECTED : "The peer closed the connection"
 @return? error::BACKEND_FAILURE : "The socket reported an error"
*>
fn bool? Display.flush(&self)
{
	self.require_open()!;
	while (self.outbox.len() > 0)
	{
		Outgoing* head = self.outbox.get_ref(0);
		char[] rest    = head.bytes[head.sent:(usz)head.bytes.len - head.sent];
		usz accepted;
		if (catch err = native_send(self.socket, rest, head.fds[0:head.fd_count], &accepted))
		{
			if (err == error::BUSY) return false;
			self.failed = true;
			return err~;
		}
		if (head.fd_count > 0)
		{
			// The kernel holds its own copies of the descriptors now; ours are closed.
			self.drop_fds(head);
		}
		head.sent += accepted;
		if (head.sent == (usz)head.bytes.len)
		{
			self.release_outgoing(head);
			self.outbox.remove_first()!!;
		}
	}
	return true;
}

<*
 Read what the socket has and handle every complete message in it. Events are
 delivered to their listeners before this returns. A non-blocking display with nothing
 to read returns 0.

 @return "How many messages were handled"
 @return? error::DISCONNECTED : "The compositor closed the connection"
 @return? error::PROTOCOL : "A message was malformed, named an unknown object, or was a `wl_display.error`"
 @return? error::BACKEND_FAILURE : "The socket reported an error"
*>
fn usz? Display.dispatch(&self)
{
	self.require_open()!;
	if (catch err = self.receive())
	{
		self.failed = true;
		return err~;
	}
	usz handled = 0;
	while (true)
	{
		char[] available  = self.inbox[0:self.inbox_len];
		wire::Frame frame = wire::read_frame(available)!;
		if (!frame.complete) break;
		if (catch err = self.deliver(frame, available))
		{
			self.failed = true;
			return err~;
		}
		usz rest = self.inbox_len - frame.size;
		mem::move(self.inbox.ptr, self.inbox.ptr + frame.size, (sz)rest);
		self.inbox_len = rest;
		handled++;
	}
	return handled;
}

<*
 Raise a protocol error the compositor sent (`wl_display.error`). The display is failed
 from then on. Called by the generated code.
*>
fn void? Display.protocol_error(&self, uint object_id, uint code, String message)
{
	self.failed = true;
	fault f = error::PROTOCOL;
	if (code == ERROR_NO_MEMORY) f = error::NO_MEMORY;
	if (code == ERROR_IMPLEMENTATION) f = error::BACKEND_FAILURE;
	return error::raise(f, error::Domain.WAYLAND, (int)code, "object %d: %s (error %d)", object_id, message, code)~;
}

<* Close a descriptor that arrived but will not be used. Called by the generated code. *>
fn void Display.close_native(&self, rt::Native fd) @inline => native_close(fd);

// Fail when the display was closed or a protocol error has already happened.
fn void? Display.require_open(&self)
{
	if (!self.open)
	{
		return error::raise(error::INVALID_STATE, error::Domain.INTERNAL, 0, "the display is closed")~;
	}
	if (self.failed)
	{
		return error::raise(
			error::INVALID_STATE,
			error::Domain.INTERNAL,
			0,
			"the display failed with a protocol error"
		)~;
	}
}

// Add a proxy to the table. The version is the lower of the requested one and the interface's own.
fn Proxy*? Display.insert(&self, uint id, Interface iface, uint version)
{
	Proxy* proxy = alloc::new(self.allocator, Proxy);
	*proxy = { .id = id, .iface = iface, .version = min(version, iface.version), .conn = self };
	self.objects.push(proxy);
	return proxy;
}

// A released client id if there is one, otherwise the next unused one.
fn uint? Display.allocate_id(&self)
{
	if (try id = self.free_ids.pop()) return id;
	if (self.next_id >= SERVER_ID_START)
	{
		return error::raise(error::OUT_OF_RANGE, error::Domain.INTERNAL, 0, "all client object ids are in use")~;
	}
	return self.next_id++;
}

// Close the descriptors of a queued message and forget them.
fn void Display.drop_fds(&self, Outgoing* out)
{
	foreach (fd : out.fds[0:out.fd_count]) native_close(fd);
	out.fd_count = 0;
}

// Drop the descriptors and the bytes of a queued message.
fn void Display.release_outgoing(&self, Outgoing* out)
{
	self.drop_fds(out);
	if (out.bytes.len > 0) alloc::free(self.allocator, out.bytes.ptr);
	out.bytes = { };
}

// Read what is available into the inbox, queueing any descriptors that came with it.
// Nothing to read on a non-blocking socket is not an error.
fn void? Display.receive(&self)
{
	rt::Native[wire::MAX_FDS_PER_MESSAGE] arrived;
	Received got;
	usz room = INBOX_CAPACITY - self.inbox_len;
	if (catch err = native_recv(self.socket, self.inbox[self.inbox_len:room], arrived[..], &got))
	{
		if (err == error::BUSY) return;
		return err~;
	}
	for (usz i = 0; i < got.fds; i++)
	{
		if (catch err = self.incoming.push(arrived[i]))
		{
			foreach (fd : arrived[i:got.fds - i]) native_close(fd);
			return err~;
		}
	}
	self.inbox_len += got.bytes;
}

// Hand one complete message to its object's dispatch function.
fn void? Display.deliver(&self, wire::Frame frame, char[] available)
{
	Proxy* proxy = self.find(frame.object);
	if (proxy == null)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "message for unknown object %d", frame.object)~;
	}
	wire::Reader args = { .data = frame.payload(available), .pos = 0, .fds = &self.incoming };
	proxy.iface.dispatch(self, proxy, frame.opcode, &args)!;
	args.expect_end()!;
}