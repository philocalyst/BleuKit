<*
 The UPower backend: the system bus, org.freedesktop.UPower.

 Preferred over sysfs (priority 20 against 10). The worker owns one D-Bus connection,
 registered with its poller, and reads UPower whenever a signal arrives or the poll
 interval passes:
 - org.freedesktop.DBus.Properties.PropertiesChanged under /org/freedesktop/UPower
 (subtree), which covers every device object;
 - DeviceAdded and DeviceRemoved on /org/freedesktop/UPower.
 The handlers only set a flag; the state is read after the connection has processed its
 messages, on the worker thread, as `bleu_dbus` requires.

 When the system bus is unreachable or the UPower name has no owner, the backend is not
 offered (`probe` is false) and sysfs is used. If the bus goes away while running, the
 connection is retried on each poll tick.

 Options.root (a fake sysfs tree in tests) disables this backend: a fake tree describes
 sysfs, not UPower.
*>
module bleu::battery::upower @feat(LINUX);
import std::time, bleu::availability, bleu::battery, bleu::dbus::connection, bleu::dbus::match, bleu::dbus::message, bleu::dbus::proxy, bleu::error, bleu::observe, bleu::rt, bleu::rt::poller, bleu::rt::worker, bleu::service;

// The poller tag of the bus connection. The worker's wake-up is not tagged (see bleu_rt).
const usz CONNECTION_TAG = 1;

struct Backend
{
	Allocator allocator;
	Duration poll;
	Connection connection;
	bool connected;
	bool changed;
}

const Driver DRIVER = {
	.info = { "upower", "UPower on the system bus (org.freedesktop.UPower)", 20 },
	.id = UPOWER,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

<*
 Whether the UPower name has an owner on the system bus. The connection used for the
 check is closed again before returning.
*>
fn bool probe(Options* options)
{
	if (options.root.len > 0) return false;
	Connection connection;
	connection.init(mem);
	defer connection.free();
	if (catch connection.open_system()) return false;
	defer connection.close();
	if (try owned = connection.name_has_owner(UPOWER_NAME)) return owned;
	return false;
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.set(
		Cap.TEMPERATURE,
		availability::no(
			availability::Reason.DEGRADED,
			"Reported only by devices whose kernel driver exposes a temperature"
		)
	);
	capabilities.set(
		Cap.CYCLES,
		availability::no(availability::Reason.DEGRADED, "ChargeCycles is -1 where the driver does not report it")
	);
	Backend* backend = alloc::new(allocator, Backend, { .allocator = allocator, .poll = options.poll });
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

// Property changes anywhere under the UPower object tree: read the state again.
fn void on_properties(void* context, proxy::PropertyChange* change) @local
{
	Backend* backend = (Backend*)context;
	backend.changed = true;
}

// DeviceAdded and DeviceRemoved: a device came or went, read the state again.
fn void on_device_signal(void* context, message::Message* signal) @local
{
	Backend* backend = (Backend*)context;
	backend.changed = true;
}

<*
 Open the system bus, subscribe to the UPower signals and register the connection with
 the poller. On failure nothing stays open.

 @return? error::UNAVAILABLE : "when the system bus cannot be reached"
*>
fn void? connect(Backend* backend, Poller* poller)
{
	backend.connection.init(backend.allocator);
	if (catch err = backend.connection.open_system())
	{
		backend.connection.free();
		return err~;
	}
	if (catch err = subscribe(backend))
	{
		backend.connection.close();
		backend.connection.free();
		return err~;
	}
	int fd = backend.connection.fd()!;
	if (catch err = poller.add({ .handle = (rt::Native)fd, .interest = { .readable = true }, .tag = CONNECTION_TAG }))
	{
		backend.connection.close();
		backend.connection.free();
		return err~;
	}
	backend.connected = true;
}

<* Close the connection and take it out of the poller. Safe when not connected. *>
fn void disconnect(Backend* backend, Poller* poller)
{
	if (!backend.connected) return;
	backend.connected = false;
	if (catch poller.remove(CONNECTION_TAG))
	{
		// Not registered: nothing to remove.
	}
	backend.connection.close();
	backend.connection.free();
}

<* The subscriptions the connection needs. They end with the connection. *>
fn void? subscribe(Backend* backend)
{
	proxy::Proxy root = proxy::for_object(&backend.connection, UPOWER_NAME, UPOWER_PATH, UPOWER_INTERFACE)!;
	if (catch err = root.watch_properties(&on_properties, backend, true)) return err~;
	match::Match rule;
	rule.init(backend.allocator);
	rule.with_type(message::MessageType.SIGNAL)!!;
	rule.with_sender(UPOWER_NAME)!!;
	rule.with_interface(UPOWER_INTERFACE)!!;
	rule.with_path(UPOWER_PATH)!!;
	if (catch err = backend.connection.subscribe(rule, &on_device_signal, backend)) return err~;
}

<* The state from UPower now. UNAVAILABLE while the connection is down. *>
fn State? read_current(Backend* backend, Allocator allocator)
{
	if (!backend.connected) return error::UNAVAILABLE~;
	return read_all(allocator, &backend.connection);
}

<* Publish the state now. An unreadable UPower is an empty state: nothing is known. *>
fn void refresh(Backend* backend, BatteryHub* hub)
{
	Snapshot{State}* snapshot = hub.begin();
	if (try state = read_current(backend, snapshot.allocator()))
	{
		snapshot.value = state;
	}
	else
	{
		snapshot.value = { };
	}
	hub.publish_if_changed(snapshot);
}

fn void run(void* state, BatteryHub* hub, Host{Command}* host)
{
	Backend* backend = (Backend*)state;
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	if (catch connect(backend, &poller))
	{
		// UPower is not reachable yet: each poll tick tries again, and the state stays empty.
	}
	refresh(backend, hub);
	Command[8] commands;
	while (!host.stopping())
	{
		// Sleeps until the poll interval passes, the bus has data, or a refresh is queued.
		bool timed_out = false;
		if (catch poller.wait(backend.poll))
		{
			timed_out = true;
		}
		if (backend.connected)
		{
			if (catch backend.connection.process())
			{
				// The bus went away: the next tick reconnects.
				disconnect(backend, &poller);
				backend.changed = true;
			}
		}
		usz count      = host.mailbox().take_all(commands[..]);
		bool requested = count > 0;
		if (!backend.connected)
		{
			if (catch connect(backend, &poller))
			{
				// Still unreachable; the empty state stands.
			}
		}
		if (timed_out || requested || backend.changed)
		{
			backend.changed = false;
			refresh(backend, hub);
		}
	}
	disconnect(backend, &poller);
}