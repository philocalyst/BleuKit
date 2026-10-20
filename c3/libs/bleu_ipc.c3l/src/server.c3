<*
 A server for the DMS IPC protocol: newline-delimited JSON requests and replies on
 a Unix socket, and subscriptions that stream state, wire-compatible with
 dankgo's `ipc` package and DMS's `server` (see docs/research/bleu_ipc.md and
 the README for the exact list of behaviours that are and are not reproduced).

 Threads:
 * one I/O thread owns the listener, every connection, every outbox and every
   subscription. Nothing else touches them, so no lock guards them.
 * `workers` handler threads run the registered methods, one request each.
   A blocking handler stalls only its own thread: ping, subscribe and the
   I/O of other clients keep working.
 * publishers (`Topic.publish`) may run on any thread. They store the snapshot
   under the topic's mutex and post the fan-out to the I/O thread in the same
   critical section, so the I/O thread sees publications in the order they
   were made.

 Lifecycle: `init`, then `register_method` and `register_topic`, then `start`,
 then `stop`, then `free`. Registration is refused once the server has started,
 because the I/O thread reads the method and topic tables without a lock. The
 server must not be moved in memory after `init`; its threads refer to it.
*>
module bleu::ipc @feat(POSIX);
import std::collections::list, std::atomic, std::thread, bleu::error, bleu::rt, bleu::rt::worker, bleu::rt::poller, bleu::rt::unix, bleu::ipc::wire, bleu::ipc::line, bleu::ipc::outbox;

<*
 Produces the capability names for the handshake and for the `server` service.
 Runs on the I/O thread: it must not block and must not call into the server.
 The returned slice is read before the call returns and is not kept.

 @param context : "The `capabilities_context` of the Config"
 @return "Capability names, in the order they are sent"
*>
alias CapabilitiesFn = fn String[](void* context);

<*
 A method handler. Runs on a handler thread. It must answer the request, either
 by returning after `call.respond_*`, or by taking a `Deferred` with
 `call.defer()` and answering later from any thread. A handler that returns
 without either is answered with an error.

 @param context : "The context given to `register_method`"
 @param call : "The request being answered; valid until the handler returns, except through a Deferred"
*>
alias Handler = fn void(void* context, Call* call);

<* Default maximum of unsent bytes queued for one client. *>
const usz DEFAULT_MAX_QUEUED_BYTES = 32 * 1024 * 1024;

<* Default number of simultaneously connected clients. *>
const usz DEFAULT_MAX_CLIENTS = 64;

<* Default number of handler threads. *>
const int DEFAULT_WORKERS = 4;

<* Default time a client may leave its output unread before it is disconnected. DMS: 30 s (dankgo ipc/writer.go:14). *>
const Duration DEFAULT_WRITE_STALL = (Duration)30_000_000;

<* Capacity of the I/O thread's command queue. Publications beyond it are refused with BUSY. *>
const usz IO_QUEUE_CAPACITY = 4096;

<* Capacity of each handler thread's queue. A request beyond it is answered with "server is busy". *>
const usz POOL_QUEUE_CAPACITY = 256;

<* Pending connections the kernel queues on the listening socket. *>
const int LISTEN_BACKLOG = 128;

<* Poller tag of the listening socket. Connection ids start at 1, so no connection has it. *>
const usz LISTENER_TAG = 0;

<*
 Coalescing key of the `server` service frames (capability changes). Topic
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
	// Protocol version the handshake reports (DMS sends 38).
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

<* A registered method. *>
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
	// is like this, because only one client should act on those commands.
	bool explicit_only;
}

<*
 A named stream of state. `publish` replaces the state every subscriber sees
 (and the snapshot a new subscriber starts from); `publish_event` sends one
 occurrence to the subscribers that are connected now.
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
	UnixSocket listener;
	String socket_path;
	List{Connection*} connections;
	usz next_connection_id;
	PoolSlot[] slots;
}

<*
 Prepare a server: queues and worker objects are created, no thread runs and no
 socket is bound.

 @param allocator : "Allocator for everything the server owns"
 @require allocator != null : "The server needs an allocator"
 @return? error::INVALID_ARGUMENT : "No app name and no socket path, or a negative worker count"
 @return? error::BACKEND_FAILURE : "The wake-up of the I/O thread could not be created"
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
	self.methods.init(allocator, 8);
	self.topics.init(allocator, 8);
	self.connections.init(allocator, 16);
	self.slots = alloc::new_array(allocator, PoolSlot, (sz)self.config.workers);
	for (int i = 0; i < self.config.workers; i++)
	{
		if (catch err = self.slots[i].worker.init(allocator, POOL_QUEUE_CAPACITY))
		{
			for (int j = 0; j < i; j++) self.slots[j].worker.free();
			alloc::free(allocator, self.slots.ptr);
			self.io.free();
			return err~;
		}
	}
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
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "method name '%s' is empty or built in", name)~;
	}
	if (self.find_method(name) != null)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "method '%s' is already registered", name)~;
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

 @param name : "The service name, as `services` in a subscribe request names it"
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
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "topic name '%s' is empty, reserved or taken", name)~;
	}
	Topic* topic = alloc::new(self.allocator, Topic);
	topic.server = self;
	topic.name = name.copy(self.allocator);
	topic.options = options;
	topic.index = self.topics.len();
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
 Bind the socket, then start the I/O thread and the handler threads. Clients may
 connect as soon as this returns. A socket that was left behind by a process that
 no longer exists is removed first; another socket at the same path is an error.

 @return? error::INVALID_STATE : "The server has already started or stopped"
 @return? error::UNAVAILABLE : "No socket path was given and XDG_RUNTIME_DIR is not set"
 @return? error::BACKEND_FAILURE, error::PERMISSION_DENIED : "The socket could not be bound or a thread could not start"
*>
fn void? Server.start(&self)
{
	if (self.state != NEW)
	{
		return error::raise(error::INVALID_STATE, error::Domain.INTERNAL, 0, "server was already started or stopped")~;
	}
	self.socket_path = resolve_socket_path(self.allocator, self.config)!;
	if (catch err = self.start_threads())
	{
		self.release_socket();
		return err~;
	}
	self.state = RUNNING;
}

// Bind the socket and start the threads. On failure the caller releases what is left.
fn void? Server.start_threads(&self) @private
{
	self.listener = bind_socket(self.socket_path, self.config.app_name.len == 0 || self.config.socket_path.len > 0)!;
	self.listener.fd.set_nonblocking(true)!;
	self.io_poller.init(self.allocator, self.io.mailbox.wakeup(), self.config.max_clients + 1)!;
	self.io_poller.add({ .handle = self.listener.fd.raw(), .interest = read_interest(), .tag = LISTENER_TAG })!;
	for (int i = 0; i < self.config.workers; i++)
	{
		PoolSlot* slot = &self.slots[i];
		slot.waiter.init(self.allocator, slot.worker.mailbox.wakeup(), 1)!;
		slot.worker.start("bleu-ipc-handler", &pool_main, slot)!;
	}
	self.io.start("bleu-ipc-io", &io_main, self)!;
}

// Undo a partly completed start: stop what runs, release the socket and the poller.
fn void Server.release_socket(&self) @private
{
	self.listener.close();
	if (self.socket_path.len > 0)
	{
		if (catch io::path::delete(self.socket_path)) {}
		alloc::free(self.allocator, self.socket_path.ptr);
	}
	self.socket_path = "";
}

<*
 Stop accepting, close every client and stop the handler threads. A handler
 that is running finishes first, so this may wait for it. Replies that arrive
 after this complete with UNAVAILABLE. Idempotent. Must not be called from a
 handler or from a subscriber callback.
*>
fn void Server.stop(&self)
{
	if (self.state != RUNNING) return;
	self.io.stop();
	for (int i = 0; i < self.config.workers; i++)
	{
		self.slots[i].worker.stop();
		self.slots[i].waiter.free();
	}
	self.io_poller.free();
	if (catch io::path::delete(self.socket_path)) {}
	self.state = STOPPED;
}

<*
 Stop the server if it runs, release all of its memory and the topics. After
 this, the `Topic` pointers and any `Deferred` that was not completed are invalid.

 @require the server is not in use by a handler that is still running : "stop() has joined every handler thread"
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
	for (int i = 0; i < self.config.workers; i++) self.slots[i].worker.free();
	alloc::free(self.allocator, self.slots.ptr);
	self.io.free();
	if (self.socket_path.len > 0) alloc::free(self.allocator, self.socket_path.ptr);
	self.socket_path = "";
}

<*
 Tell every subscriber that the capabilities changed: a `server` frame carrying
 the new `ServerInfo` is sent on each subscription, as DMS does.

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

<* The server's life-cycle state, for a caller that wants to report it. *>
fn ServerState Server.state_of(&self) @inline => self.state;

// The capability names of the server, now.
fn String[] Server.capabilities_now(&self) @private
{
	if (self.config.capabilities_fn != null) return self.config.capabilities_fn(self.config.capabilities_context);
	return self.config.capabilities;
}

<*
 Bind and listen on a socket path. A path left behind by an earlier process with
 the same pid is removed first when `owned` is set; any other existing path
 fails. The socket is made owner-only, as DMS does (dankgo ipc/server.go:78).
*>
fn unix::UnixSocket? bind_socket(String path, bool owned) @private
{
	if (owned)
	{
		if (catch io::path::delete(path)) {}
	}
	unix::UnixSocket socket = unix::listen(path, STREAM, LISTEN_BACKLOG)!;
	if (chmod_owner_only(path) != 0)
	{
		socket.close();
		return error::raise(error::BACKEND_FAILURE, error::Domain.ERRNO, libc::errno(), "cannot restrict socket '%s'", path)~;
	}
	return socket;
}
