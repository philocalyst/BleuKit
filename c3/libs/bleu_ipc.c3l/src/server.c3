<*
 A server for the DMS IPC protocol: newline-delimited JSON requests and replies on
 a Unix socket, and subscriptions that stream state. It is wire-compatible with
 dankgo's `ipc` package and DMS's `server` service; docs/research/bleu_ipc.md
 and the README list exactly what is reproduced and what is not.

 Threads:
 * one I/O thread owns the listener, every connection, every outbox and every
   subscription. Nothing else touches them, so no lock guards them.
 * `workers` handler threads run the registered methods, one request each. A
   blocking handler stalls only its own thread: ping, subscribe and the I/O of
   other clients keep working.
 * publishers (`Topic.publish`) may run on any thread. They store the snapshot
   under the topic's mutex and post the fan-out to the I/O thread inside the same
   critical section, so the I/O thread sees publications in the order they were
   made.

 Life cycle: `init`, then `register_method` and `register_topic`, then `start`,
 then `stop`, then `free`. Registration is refused once the server has started,
 because the I/O thread reads the method and topic tables without a lock. The
 server must not be moved in memory after `init`: its threads refer to it.
*>
module bleu::ipc @feat(POSIX);
import std::collections::list, std::atomic, std::thread, std::time, std::io, libc, bleu::error, bleu::rt::worker, bleu::rt::poller, bleu::rt::unix, bleu::ipc::wire, bleu::ipc::line, bleu::ipc::outbox;

<*
 Produces the capability names for the handshake and for the `server` service.
 Runs on the I/O thread: it must not block and must not call into the server.
 The returned slice is read before the call returns and is not kept.

 @param context : "The `capabilities_context` of the Config"
 @return "Capability names, in the order they are sent"
*>
alias CapabilitiesFn = fn String[](void* context);

<*
 A method handler. Runs on a handler thread. It answers the request either by
 calling `call.respond_*` before it returns, or by taking a `Deferred` with
 `call.defer_reply()` and answering later from any thread. A handler that returns
 without either is answered with an error.

 @param context : "The context given to `register_method`"
 @param call : "The request; valid until the handler returns, except through a Deferred"
*>
alias Handler = fn void(void* context, Call* call);

<* Default bound on unsent bytes queued for one client. *>
const usz DEFAULT_MAX_QUEUED_BYTES = 32 * 1024 * 1024;

<* Default number of simultaneously connected clients. *>
const usz DEFAULT_MAX_CLIENTS = 64;

<* Default number of handler threads. *>
const int DEFAULT_WORKERS = 4;

<* Default time a client may leave its output unread before it is disconnected: DMS's 30 s (dankgo ipc/writer.go:14). *>
const Duration DEFAULT_WRITE_STALL = (Duration)30_000_000;

<* Capacity of the I/O thread's command queue. Publications beyond it are refused with BUSY. *>
const usz IO_QUEUE_CAPACITY = 4096;

<* Capacity of each handler thread's queue. A request beyond it is answered "server is busy". *>
const usz POOL_QUEUE_CAPACITY = 256;

<* Connections the kernel queues on the listening socket. *>
const int LISTEN_BACKLOG = 128;

<* Poller tag of the listening socket. Connection ids start at 1, so no connection has this tag. *>
const usz LISTENER_TAG = 0;

<*
 Coalescing key of the `server` service frames sent on a capability change. Topic
 indices are small, so this never collides with a topic's key.
*>
const usz SERVER_KEY = usz::max - 1;

<*
 Configuration of a server. Every field left at its zero value takes the default
 named in its comment, so `Config{ .app_name = "dmsd", .api_version = 38 }` is a
 complete configuration.
*>
struct Config
{
	// Name in the socket file name `<app_name>-<pid>.sock`. Required unless `socket_path` is set.
	String app_name;
	// Protocol version the handshake reports. DMS sends 38.
	int api_version;
	// Capability names, used when `capabilities_fn` is null.
	String[] capabilities;
	// Computes the capability names; takes precedence over `capabilities`.
	CapabilitiesFn capabilities_fn;
	// Passed to `capabilities_fn`.
	void* capabilities_context;
	// Full socket path. Empty selects `$XDG_RUNTIME_DIR/<app_name>-<pid>.sock`.
	String socket_path;
	// Longest request line in bytes, not counting its newline. Default `wire::DEFAULT_MAX_LINE`.
	usz max_line;
	// Handler threads. Default 4.
	int workers;
	// Longest a client may leave its output unread before it is disconnected. Default 30 s.
	Duration write_stall;
	// Unsent bytes one client may have queued. Default 32 MiB.
	usz max_queued_bytes;
	// Clients connected at once; the next one is closed on accept. Default 64.
	usz max_clients;
}

<* Where the server is in its life cycle. *>
enum ServerState : char
{
	NEW,
	RUNNING,
	STOPPED,
}

<* A registered method. Owned by the server. *>
struct Method
{
	String name;
	Handler handler;
	void* context;
}

<* Options of a topic. *>
struct TopicOptions
{
	// The topic is left out of `"all"`: a client must name it. DMS's `mpris.command`
	// works this way, because only one client should act on those commands.
	bool explicit_only;
}

<*
 A named stream of state. `publish` replaces the state that every subscriber sees,
 and the snapshot a new subscriber starts from. `publish_event` sends one
 occurrence to the subscribers connected at that moment, and keeps no snapshot.
*>
struct Topic
{
	Server* server;
	String name;
	TopicOptions options;
	usz index;
	Atomic{int} subscribers;
	Mutex mutex;
	bool has_snapshot;
	String snapshot;
}

<* The server. See the module documentation for threads and life cycle. *>
struct Server
{
	Allocator allocator;
	Config config;
	ServerState state;
	List{Method*} methods;
	List{Topic*} topics;
	worker::Worker{IoCommand} io;
	poller::Poller io_poller;
	bool io_poller_ready;
	unix::UnixSocket listener;
	bool listening;
	String socket_path;
	List{Connection*} connections;
	usz next_connection_id;
	PoolSlot[] slots;
}

<*
 Prepare a server. Queues and worker objects are created; no thread runs and no
 socket is bound.

 @param allocator : "Allocator for everything the server owns"
 @require allocator != null : "The server needs an allocator"
 @return? error::INVALID_ARGUMENT : "No app name and no socket path, or a negative worker count"
 @return? error::BACKEND_FAILURE : "A worker's wake-up could not be created"
*>
fn void? Server.init(&self, Allocator allocator, Config config)
{
	if (config.app_name.len == 0 && config.socket_path.len == 0)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "server needs an app name or a socket path")~;
	}
	if (config.workers < 0)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "server needs a non-negative worker count")~;
	}
	self.allocator = allocator;
	self.config = resolve_defaults(config);
	self.state = NEW;
	self.next_connection_id = 1;
	self.io.init(allocator, IO_QUEUE_CAPACITY)!;
	self.slots = alloc::new_array(allocator, PoolSlot, (sz)self.config.workers);
	for (sz i = 0; i < (sz)self.config.workers; i++)
	{
		if (catch err = self.slots[i].worker.init(allocator, POOL_QUEUE_CAPACITY))
		{
			for (sz j = 0; j < i; j++) self.slots[j].worker.free();
			alloc::free(allocator, self.slots.ptr);
			self.io.free();
			return err~;
		}
	}
	self.methods.init(allocator, 8);
	self.topics.init(allocator, 8);
	self.connections.init(allocator, 16);
}

// Fill every zero field of a configuration with its default.
fn Config resolve_defaults(Config config) @private
{
	if (config.max_line == 0) config.max_line = wire::DEFAULT_MAX_LINE;
	if (config.workers == 0) config.workers = DEFAULT_WORKERS;
	if (config.write_stall == time::DURATION_ZERO) config.write_stall = DEFAULT_WRITE_STALL;
	if (config.max_queued_bytes == 0) config.max_queued_bytes = DEFAULT_MAX_QUEUED_BYTES;
	if (config.max_clients == 0) config.max_clients = DEFAULT_MAX_CLIENTS;
	return config;
}

<*
 Register the handler of a method name. Names are case-sensitive. `ping` and
 `subscribe` are built in and cannot be registered.

 @param name : "The `method` a client sends"
 @param handler : "Runs on a handler thread, once per request"
 @param context : "Passed to the handler unchanged; must outlive the server"
 @require handler != null : "A method needs a handler"
 @return? error::INVALID_STATE : "The server has started"
 @return? error::INVALID_ARGUMENT : "Empty name, a built-in name, or a name already registered"
*>
fn void? Server.register_method(&self, String name, Handler handler, void* context)
{
	if (self.state != NEW)
	{
		return error::raise(error::INVALID_STATE, error::Domain.INTERNAL, 0, "methods must be registered before start")~;
	}
	if (name.len == 0 || name == "ping" || name == "subscribe")
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "method name is empty or built in")~;
	}
	if (self.find_method(name) != null)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "method name is already registered")~;
	}
	Method* method = alloc::new(self.allocator, Method);
	method.name = name.copy(self.allocator);
	method.handler = handler;
	method.context = context;
	self.methods.push(method);
}

// The registered method called `name`, or null.
fn Method* Server.find_method(&self, String name)
{
	for (sz i = 0; i < self.methods.len(); i++)
	{
		Method* method = self.methods.get(i);
		if (method.name == name) return method;
	}
	return null;
}

<*
 Register a topic: a service name a client can subscribe to. Topics are numbered
 in registration order.

 @param name : "The service name, as a subscribe request's `services` names it"
 @return "The topic, owned by the server; valid until `free`"
 @return? error::INVALID_STATE : "The server has started"
 @return? error::INVALID_ARGUMENT : "Empty name, the reserved name `server`, or a name already registered"
*>
fn Topic*? Server.register_topic(&self, String name, TopicOptions options = {})
{
	if (self.state != NEW)
	{
		return error::raise(error::INVALID_STATE, error::Domain.INTERNAL, 0, "topics must be registered before start")~;
	}
	if (name.len == 0 || name == "server" || self.find_topic(name) != null)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "topic name is empty, reserved or taken")~;
	}
	Topic* topic = alloc::new(self.allocator, Topic);
	topic.server = self;
	topic.name = name.copy(self.allocator);
	topic.options = options;
	topic.index = (usz)self.topics.len();
	topic.subscribers.store(0);
	topic.mutex.init()!!;
	topic.has_snapshot = false;
	self.topics.push(topic);
	return topic;
}

// The registered topic called `name`, or null.
fn Topic* Server.find_topic(&self, String name)
{
	for (sz i = 0; i < self.topics.len(); i++)
	{
		Topic* topic = self.topics.get(i);
		if (topic.name == name) return topic;
	}
	return null;
}

<*
 Bind the socket and start the threads. Clients may connect as soon as this
 returns. With the default socket path, sockets left by processes that no longer
 exist are removed first (see `resolve_socket_path`).

 @return? error::INVALID_STATE : "The server has already started or stopped"
 @return? error::UNAVAILABLE : "No socket path was given and XDG_RUNTIME_DIR is not set"
 @return? error::BACKEND_FAILURE, error::PERMISSION_DENIED, error::INVALID_ARGUMENT : "The socket could not be bound, or a thread could not start"
*>
fn void? Server.start(&self)
{
	if (self.state != NEW)
	{
		return error::raise(error::INVALID_STATE, error::Domain.INTERNAL, 0, "server was already started or stopped")~;
	}
	bool owned = self.config.socket_path.len == 0;
	self.socket_path = resolve_socket_path(self.allocator, self.config)!;
	unix::UnixSocket? bound = bind_socket(self.socket_path, owned);
	if (catch err = bound)
	{
		alloc::free(self.allocator, self.socket_path.ptr);
		self.socket_path = "";
		return err~;
	}
	self.listener = bound;
	self.listening = true;
	if (catch err = self.start_threads())
	{
		self.release_listener();
		return err~;
	}
	self.state = RUNNING;
}

// Start the handler threads, the poller and the I/O thread. Undoes what it started on failure.
fn void? Server.start_threads(&self)
{
	for (sz i = 0; i < (sz)self.config.workers; i++)
	{
		PoolSlot* slot = &self.slots[i];
		if (catch err = slot.start(self.allocator))
		{
			self.stop_slots(i);
			return err~;
		}
	}
	if (catch err = self.io_poller.init(self.allocator, self.io.mailbox.wakeup(), self.config.max_clients + 1))
	{
		self.stop_slots((sz)self.config.workers);
		return err~;
	}
	self.io_poller_ready = true;
	if (catch err = self.io_poller.add({ .handle = self.listener.fd.raw(), .interest = connection_interest(false), .tag = LISTENER_TAG }))
	{
		self.stop_slots((sz)self.config.workers);
		self.release_poller();
		return err~;
	}
	if (catch err = self.io.start("bleu-ipc-io", &io_main, self))
	{
		self.stop_slots((sz)self.config.workers);
		self.release_poller();
		return err~;
	}
}

// Stop the first `count` handler threads and release their pollers.
fn void Server.stop_slots(&self, sz count)
{
	for (sz i = 0; i < count; i++)
	{
		self.slots[i].worker.stop();
		self.slots[i].waiter.free();
	}
}

// Release the poller of the I/O thread, if it was set up.
fn void Server.release_poller(&self)
{
	if (!self.io_poller_ready) return;
	self.io_poller.free();
	self.io_poller_ready = false;
}

// Close the listening socket and remove its path, if this server bound it.
fn void Server.release_listener(&self)
{
	if (self.listening)
	{
		self.listener.close();
		if (catch io::path::delete((io::path::Path)self.socket_path)) {}
		self.listening = false;
	}
	if (self.socket_path.len > 0) alloc::free(self.allocator, self.socket_path.ptr);
	self.socket_path = "";
}

<*
 Stop accepting, close every client and stop the handler threads. A handler that
 is running finishes first, so this may wait for it. Replies that arrive after
 this complete with UNAVAILABLE. Idempotent. Must not be called from a handler.
*>
fn void Server.stop(&self)
{
	if (self.state != RUNNING) return;
	self.io.stop();
	self.stop_slots((sz)self.config.workers);
	self.release_poller();
	self.release_listener();
	self.state = STOPPED;
}

<*
 Stop the server if it runs, then release its memory, its topics and its methods.
 After this, every `Topic` pointer is invalid, and a `Deferred` that was never
 completed is leaked. No handler may still be running: `stop` joins the handler
 threads, and this must be called only after it has returned.
*>
fn void Server.free(&self)
{
	self.stop();
	for (sz i = 0; i < self.topics.len(); i++)
	{
		Topic* topic = self.topics.get(i);
		topic.mutex.destroy();
		alloc::free(self.allocator, topic.name.ptr);
		if (topic.has_snapshot) alloc::free(self.allocator, topic.snapshot.ptr);
		alloc::free(self.allocator, topic);
	}
	for (sz i = 0; i < self.methods.len(); i++)
	{
		Method* method = self.methods.get(i);
		alloc::free(self.allocator, method.name.ptr);
		alloc::free(self.allocator, method);
	}
	self.topics.free();
	self.methods.free();
	self.connections.free();
	for (sz i = 0; i < (sz)self.config.workers; i++) self.slots[i].worker.free();
	alloc::free(self.allocator, self.slots.ptr);
	self.io.free();
	*self = { };
}

<*
 Tell every subscriber that the capabilities changed: a `server` frame carrying
 the new `ServerInfo` goes out on each subscription, as DMS does.

 @return? error::UNAVAILABLE : "The server is stopped"
 @return? error::BUSY : "The I/O queue is full"
*>
fn void? Server.notify_capabilities_changed(&self) @maydiscard
{
	return self.post_io({ .kind = CAPABILITIES });
}

<*
 How many subscriptions currently want a topic. Callable from any thread; the
 count is a snapshot.

 @param topic : "A topic of this server"
*>
fn int Server.subscriber_count(&self, Topic* topic) => topic.subscribers.load();

<* The capability names now, from the configured function or list. Called on the I/O thread. *>
fn String[] Server.capabilities_now(&self)
{
	if (self.config.capabilities_fn != null) return self.config.capabilities_fn(self.config.capabilities_context);
	return self.config.capabilities;
}

<*
 Bind and listen on a socket path. When `owned` is set, a file already at the path
 is ours to replace: the default path embeds this process's pid, so a leftover
 there came from an earlier process with the same pid. Otherwise an existing
 path fails. The socket is then made owner-only, as DMS does
 (dankgo ipc/server.go:78).
*>
fn unix::UnixSocket? bind_socket(String path, bool owned) @private
{
	if (owned)
	{
		if (catch io::path::delete((io::path::Path)path)) {}
	}
	unix::UnixSocket socket = unix::listen(path, unix::SocketKind.STREAM, LISTEN_BACKLOG)!;
	if (chmod_owner_only(path) != 0)
	{
		CInt code = libc::errno();
		socket.close();
		return error::raise(error::BACKEND_FAILURE, error::Domain.ERRNO, code, "cannot restrict socket '%s'", path)~;
	}
	return socket;
}
