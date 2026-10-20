<*
 The POSIX daemon: one `bleu_ipc` server, one state topic per service, and one
 method per built-in and per command of every service.

 Method names: `<service>.state`, `<service>.capabilities`, `<service>.backend`,
 each command of the service (for example `brightness.set`), and `services`.
 Requests are answered on the IPC handler threads; each command waits for its own
 operation and is cancelled if that wait times out.
*>
module bleud::daemon @feat(POSIX);
import std::io, std::thread, std::time, std::atomic, std::core::string, bleu::error, bleu::registry, bleu::ipc, bleu::json;

<* Set by SIGINT and SIGTERM; the serving loop ends when it is set. *>
Atomic{bool} stop_requested;

alias SignalHandler = fn void(int signal_number);

// POSIX signal numbers: SIGINT is 2 and SIGTERM is 15 on Linux and macOS (signal.h).
const int SIGINT  = 2;
const int SIGTERM = 15;

extern fn void* install_handler(int signal_number, SignalHandler handler) @cname("signal");

<* The handler for SIGINT and SIGTERM: only sets the flag, which is all a signal handler may do. *>
fn void on_signal(int signal_number)
{
	stop_requested.store(true);
}

<*
 The daemon's state. Heap-allocated, because every watch keeps the address of
 its slot and its topic.
*>
struct Daemon
{
	registry::Slot[registry::SERVICE_COUNT] slots;
	ipc::Topic*[registry::SERVICE_COUNT] topics;
	// The handshake's capabilities. They live here, not in a constant, because the server keeps a slice of them.
	String[3] capabilities;
	ipc::Server server;
}

<*
 Serve every open service on the socket at `socket_path` (or the default) until
 SIGINT or SIGTERM. The slots are the ones `main` opened; they are closed here.

 @return "The process exit code"
 @return? error::UNAVAILABLE : "No socket path could be chosen; the message says how to give one"
*>
fn int? serve(registry::Slot[] slots, String socket_path)
{
	String path = socket_path;
	if (path.len == 0)
	{
		String? fallback = registry::default_socket_path(mem);
		if (catch err = fallback)
		{
			io::eprintfn("bleud: %s; pass --socket", error::last().message());
			return 2;
		}
		path = fallback;
	}
	Daemon* daemon = alloc::new(mem, Daemon);
	defer alloc::free(mem, daemon);
	for (usz i = 0; i < slots.len; i++) daemon.slots[i] = slots[i];
	if (catch err = start(daemon, path))
	{
		io::eprintfn("bleud: %s: %s", path, error::last().message());
		return 2;
	}
	install_handler(SIGINT, &on_signal);
	install_handler(SIGTERM, &on_signal);
	io::eprintfn("bleud: serving %d services on %s", count_open(daemon), path);
	while (!stop_requested.load())
	{
		// A signal interrupts the sleep; that is the wake-up that lets the loop see the flag.
		if (catch err = thread::sleep(time::ms(100)))
		{
			if (err != thread::INTERRUPTED) return err~;
		}
	}
	daemon.server.stop();
	foreach (&slot : daemon.slots) slot.close();
	daemon.server.free();
	return 0;
}

<* The number of open services, for the start-up line. *>
fn int count_open(Daemon* daemon) @private
{
	int open = 0;
	foreach (&slot : daemon.slots)
	{
		if (slot.handle) open++;
	}
	return open;
}

<*
 Create the server, register every method and topic, start it, and attach the
 watches that publish each open service's state.
*>
fn void? start(Daemon* daemon, String path)
{
	daemon.capabilities = { "services", "topics", "commands" };
	daemon.server.init(
		mem,
		{ .app_name = "bleud", .api_version = 1, .capabilities = daemon.capabilities[..], .socket_path = path }
	)!;
	foreach (i, &slot : daemon.slots)
	{
		daemon.topics[i] = daemon.server.register_topic(slot.spec.name)!;
		register_service_methods(daemon, slot.spec)!;
	}
	daemon.server.register_method("services", &dispatch, daemon)!;
	daemon.server.start()!;
	foreach (i, &slot : daemon.slots)
	{
		if (!slot.handle) continue;
		// A service that cannot stream its state keeps answering requests; the topic stays empty.
		if (catch err = slot.watch(&publish_state, daemon.topics[i]))
		{
			io::eprintfn("bleud: %s: no state topic: %s", slot.spec.name, error::last().message());
		}
	}
}

<* Register `<service>.state`, `.capabilities`, `.backend` and every command of `spec`. *>
fn void? register_service_methods(Daemon* daemon, registry::Spec* spec) @private
{
	String[3] built_in = { "state", "capabilities", "backend" };
	foreach (suffix : built_in)
	{
		String name = string::tformat("%s.%s", spec.name, suffix).copy(mem);
		daemon.server.register_method(name, &dispatch, daemon)!;
	}
	foreach (&command : spec.commands)
	{
		String name = command.name.copy(mem);
		daemon.server.register_method(name, &dispatch, daemon)!;
	}
}

<* Publish one state to a topic. Runs on the service's worker thread, so it only hands the text over. *>
fn void publish_state(void* context, String text)
{
	ipc::Topic* topic = (ipc::Topic*)context;
	if (catch err = topic.publish(text))
	{
		io::eprintfn("bleud: %s: publish failed: %s", topic.name, error::last().message());
	}
}

<*
 Answer one request. The result is written into a temporary buffer and sent as a
 raw JSON value; a failure is sent as `<STATUS>: <message>`.
*>
fn void dispatch(void* context, ipc::Call* call)
{
	Daemon* daemon = (Daemon*)context;
	@pool()
	{
		DString text;
		text.init(tmem);
		json::JsonWriter out;
		out.init_dstring(&text);
		if (catch err = answer(daemon, call, &out))
		{
			call.respond_error(string::tformat("%s: %s", error::status_of(err), error::last().message()));
			return;
		}
		call.respond_raw(out.written());
	};
}

<* Route one request to its service and write its result object. *>
fn void? answer(Daemon* daemon, ipc::Call* call, json::JsonWriter* out) @private
{
	json::read::Params params = { .object = call.params };
	if (call.method == "services") return write_services(daemon, out);
	usz dot = 0;
	while (dot < call.method.len && call.method[dot] != '.') dot++;
	String service       = call.method[0:dot];
	String verb          = dot < call.method.len ? call.method[dot + 1:call.method.len - dot - 1] : "";
	registry::Slot* slot = slot_named(daemon, service)!;
	if (verb == "state") return slot.write_state(out);
	if (verb == "capabilities") return slot.write_capabilities(out);
	if (verb == "backend") return write_backend(slot, out);
	return slot.call(call.method, params, out);
}

<* `<service>.backend`: the backend in use. *>
fn void? write_backend(registry::Slot* slot, json::JsonWriter* out) @private
{
	String backend = slot.backend()!;
	return registry::write_value(out, "backend", backend);
}

<* The slot of the service named `name`. *>
fn registry::Slot*? slot_named(Daemon* daemon, String name) @private
{
	foreach (&slot : daemon.slots)
	{
		if (slot.spec.name == name) return slot;
	}
	return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no service named %s", name)~;
}

<* `services`: one summary per registered service. *>
fn void? write_services(Daemon* daemon, json::JsonWriter* out) @private
{
	out.begin_object()!;
	out.key("ok")!;
	out.put_bool(true)!;
	out.key("services")!;
	out.begin_array()!;
	foreach (&slot : daemon.slots)
	{
		slot.write_summary(out)!;
	}
	out.end_array()!;
	return out.end_object();
}