// The NetworkManager backend: the driver entry, the bus, the signal handlers
// and the worker loop. Reading, commands and pending requests are in the other
// `nm_*.c3` files of this module.
// 
// Threading: the loop, every bus call and every handler run on the worker
// thread. Signal handlers only record what happened (a flag, a transition);
// the loop acts on it after `process()` returns, so no handler calls the bus.
module bleu::network::networkmanager @feat(LINUX);
import std::io::path, std::time, std::collections::list, bleu::availability, bleu::error, bleu::network, bleu::observe, bleu::rt::poller, bleu::rt::worker, bleu::dbus::connection, bleu::dbus::match, bleu::dbus::message, bleu::dbus::marshal, bleu::dbus::proxy, bleu::dbus::value;

<* The backend's state. Allocated by `create`, released by `destroy`. *>
struct Backend
{
	Allocator allocator;
	String root; // sysfs prefix, "" for the real system
	Duration poll; // periodic read interval
	String bus_address; // D-Bus address, "" for the system bus
	Connection bus; // the D-Bus connection: opened, used and freed on the worker thread only
	Proxy nm; // the NetworkManager root object
	String wifi_path; // object path of the first Wi-Fi device, "" when none
	String wifi_name; // its interface name
	uint device_state; // its State, as of the last read
	bool radio_enabled; // WirelessEnabled, as of the last read
	long last_scan; // LastScan, as of the last read
	bool last_supplied; // the last connection was started with a passphrase
	bool changed; // a signal said something moved since the last read
	ulong transition_sequence; // numbers device transitions in arrival order
	List{Transition} transitions;
	List{Pending} pending;
}

const Driver DRIVER = {
	.info = { "networkmanager", "NetworkManager over the system D-Bus (org.freedesktop.NetworkManager)", 20 },
	.id = NETWORKMANAGER,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

<* Periodic read interval while requests are pending; they complete on signals, so this only bounds their latency. *>
const Duration PENDING_TICK = (Duration)250_000;

<* Commands taken from the mailbox per pass of the loop. *>
const usz COMMAND_BATCH = 16;

<*
 Whether NetworkManager may be reachable. The real check needs the bus, so it
 is made by `create`, which the service calls next when this returns true.
*>
fn bool probe(Options* options)
{
	return true;
}

<*
 Check on the caller's thread that NetworkManager is on the bus. The real
 connection is made later on the worker thread, because a `Connection` may only
 be used by the thread that initialised it.

 @return? error::UNAVAILABLE : "NetworkManager is not running on the bus"
*>
fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	if (catch err = probe_bus(allocator, options.bus_address)) return err~;
	Backend* self = alloc::new(
		allocator,
		Backend,
		{
			.allocator = allocator,
			.root = own_text(allocator, options.root),
			.poll = options.poll,
			.bus_address = own_text(allocator, options.bus_address),
		}
	);
	self.transitions.init(allocator);
	self.pending.init(allocator);
	fill_capabilities(capabilities);
	return self;
}

// Connect, ask whether NetworkManager owns its name, and disconnect again.
fn void? probe_bus(Allocator allocator, String address) @local
{
	Connection bus;
	bus.init(allocator);
	defer bus.free();
	if (address.len > 0)
	{
		bus.open_address(address)!;
	}
	else
	{
		bus.open_system()!;
	}
	bool running = bus.name_has_owner(NM_SERVICE)!;
	if (!running) return error::raise(
		error::UNAVAILABLE,
		error::Domain.INTERNAL,
		0,
		"NetworkManager is not running on the bus"
	)~;
}

// Offer what this backend can do. Everything else keeps its "not offered" reason.
fn void fill_capabilities(Capabilities* capabilities) @local
{
	capabilities.init(
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "not offered by the NetworkManager backend")
	);
	capabilities.set(Cap.WIFI_RADIO, availability::YES);
	capabilities.set(Cap.WIFI_SCAN, availability::YES);
	capabilities.set(Cap.WIFI_CONNECT_OPEN, availability::YES);
	capabilities.set(Cap.WIFI_CONNECT_PSK, availability::YES);
	capabilities.set(Cap.WIFI_DISCONNECT, availability::YES);
	capabilities.set(Cap.WIFI_FORGET, availability::YES);
	capabilities.set(Cap.WIFI_AUTOCONNECT, availability::YES);
	capabilities.set(Cap.SSID_VISIBILITY, availability::YES);
	capabilities.set(Cap.WIFI_BSSID, availability::YES);
	capabilities.set(Cap.INTERFACE_STATE, availability::YES);
	capabilities.set(Cap.INTERFACE_SPEED, availability::YES);
	capabilities.set(Cap.INTERFACE_COUNTERS, availability::YES);
	capabilities.set(Cap.CONNECTIVITY, availability::YES);
	capabilities.set(
		Cap.WIFI_SIGNAL_DBM,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "NetworkManager reports a 0-100 strength, not dBm")
	);
	capabilities.set(
		Cap.WIFI_SECRET_PROMPT,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"the secret agent needs D-Bus object export, which bleu_dbus does not have yet"
		)
	);
}

// Open the connection on the worker thread and subscribe to what the backend reads.
fn void? open_bus(Backend* b) @local
{
	if (b.bus_address.len > 0)
	{
		b.bus.open_address(b.bus_address)!;
	}
	else
	{
		b.bus.open_system()!;
	}
	b.nm = proxy::for_object(&b.bus, NM_SERVICE, NM_PATH, NM_IFACE)!;
	b.nm.watch_properties(&on_properties, b, true)!;
	match::Match nm_rule;
	nm_rule.init(b.allocator);
	nm_rule.with_type(MessageType.SIGNAL)!;
	nm_rule.with_interface(NM_IFACE)!;
	nm_rule.with_path_namespace(NM_PATH)!;
	b.bus.subscribe(nm_rule, &on_nm_signal, b)!;
	match::Match device_rule;
	device_rule.init(b.allocator);
	device_rule.with_type(MessageType.SIGNAL)!;
	device_rule.with_interface(NM_DEVICE_IFACE)!;
	device_rule.with_member("StateChanged")!;
	device_rule.with_path_namespace(NM_DEVICES_PATH)!;
	b.bus.subscribe(device_rule, &on_device_state, b)!;
}

fn void destroy(Allocator allocator, void* state)
{
	Backend* b = (Backend*)state;
	drop_text(allocator, b.root);
	drop_text(allocator, b.bus_address);
	drop_text(allocator, b.wifi_path);
	drop_text(allocator, b.wifi_name);
	b.transitions.free();
	b.pending.free();
	alloc::free(allocator, b);
}

// PropertiesChanged anywhere under the NetworkManager object: something moved.
fn void on_properties(void* context, PropertyChange* change)
{
	Backend* b = (Backend*)context;
	b.changed = true;
}

// Any signal of the NetworkManager object (devices added or removed, connectivity ...).
fn void on_nm_signal(void* context, Message* signal)
{
	Backend* b = (Backend*)context;
	b.changed = true;
}

// StateChanged of a device: the transition goes on the queue for the loop to apply.
fn void on_device_state(void* context, Message* signal)
{
	Backend* b = (Backend*)context;
	b.changed = true;
	// A malformed signal cannot be applied; the next read still shows the device's state.
	if (catch err = queue_transition(b, signal))
	{
	}
}

fn void? queue_transition(Backend* b, Message* signal)
{
	Reader r   = signal.reader()!;
	uint state = r.read_u32()!;
	r.read_u32()!;
	uint reason = r.read_u32()!;
	b.transition_sequence++;
	b.transitions.push(
		{
			.sequence = b.transition_sequence,
			.device = own_text(b.allocator, signal.path),
			.state = state,
			.reason = reason,
		}
	);
}

<* The loop: wait for the bus, the mailbox or the next read; run the commands; read and settle. *>
fn void run(void* state, NetworkHub* hub, Host{Command}* host)
{
	Backend* b = (Backend*)state;
	b.bus.init(b.allocator);
	defer b.bus.free();
	if (catch err = open_bus(b))
	{
		network::publish_empty(hub);
		return;
	}
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 4)) return;
	defer poller.free();
	int descriptor = b.bus.fd() ?? -1;
	if (descriptor < 0) return;
	if (catch poller.add({ .handle = (Native)descriptor, .interest = { .readable = true }, .tag = 1 })) return;
	Command[COMMAND_BATCH] commands;
	refresh(b, hub);
	while (!host.stopping())
	{
		bool woke     = true;
		Duration wait = b.pending.len() > 0 ? PENDING_TICK : b.poll;
		if (catch poller.wait(wait))
		{
			// TIMEOUT is the periodic tick: a read is due even when nothing signalled.
			woke = false;
		}
		bool lost = false;
		if (catch b.bus.process())
		{
			lost = true;
		}
		@pool()
		{
			usz count = host.mailbox().take_all(commands[..]);
			for (usz i = 0; i < count; i++)
			{
				execute(b, hub, &commands[i]);
			}
			if (lost || !woke || b.changed || count > 0 || b.pending.len() > 0)
			{
				refresh(b, hub);
			}
		};
		if (lost) break;
	}
	abandon_pending(b);
}

<*
 One read, one settle, one publication. Runs inside a pool that the loop owns.
 An unreadable bus publishes an empty picture: nothing is known about it.
*>
fn void refresh(Backend* b, NetworkHub* hub)
{
	b.changed = false;
	Snapshot{State}* snapshot = hub.begin();
	Reading reading;
	State? state              = read_state(b, snapshot.allocator(), &reading);
	if (catch err = state)
	{
		snapshot.value = { };
		reading = { };
	}
	else
	{
		snapshot.value = state;
	}
	remember(b, &reading);
	settle(b, &reading);
	network::publish_snapshot(hub, snapshot);
}

// Keep what the commands need from this read.
fn void remember(Backend* b, Reading* r) @local
{
	b.device_state = r.wifi_found ? r.device_state : 0;
	b.radio_enabled = r.radio_enabled;
	b.last_scan = r.last_scan;
	drop_text(b.allocator, b.wifi_path);
	drop_text(b.allocator, b.wifi_name);
	b.wifi_path = own_text(b.allocator, r.wifi_found ? r.wifi_path : "");
	b.wifi_name = own_text(b.allocator, r.wifi_found ? r.wifi_name : "");
}