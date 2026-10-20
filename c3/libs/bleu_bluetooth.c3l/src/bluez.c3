<*
 The BlueZ backend: adapters and devices from `org.bluez` on the D-Bus system
 bus, through `bleu::dbus`.

 Reading: BlueZ announces every change with PropertiesChanged,
 InterfacesAdded and InterfacesRemoved. Any of them marks the tree dirty; the
 worker then reads the whole object tree once (GetManagedObjects), builds a
 complete state and publishes it if it differs from the last one. Device
 disconnections are also emitted as events from the `Disconnected` signal.

 Writing: each request is a method call or a property write on the object it
 names. Long calls (Pair, Connect ...) are asynchronous: the worker stays free
 to take a CancelPairing while a Pair is waiting, and the reply completes the
 task.

 Pairing prompts are not available: the agent that BlueZ would call back needs
 a D-Bus object exported by this process, and `bleu::dbus` has no server-side
 export yet (see docs/research/bluetooth_impl.md). Pairing therefore runs
 without an agent.

 Sources: BlueZ D-Bus API documentation (org.bluez.Adapter, Device, Battery
 at the master revision; docs/research/bluetooth.md, section 2.1).
*>
module bleu::bluetooth::bluez @feat(LINUX);
import std::io::path, std::time, bleu::availability, bleu::bluetooth, bleu::dbus, bleu::dbus::connection,
	bleu::dbus::match, bleu::dbus::message, bleu::dbus::proxy, bleu::error, bleu::observe, bleu::rt::poller,
	bleu::rt::worker, bleu::service;

<* The well-known name of BlueZ on the system bus. *>
const BLUEZ_NAME = "org.bluez";
<* The root of BlueZ's object tree. *>
const BLUEZ_ROOT = "/";
const ADAPTER_IFACE = "org.bluez.Adapter1";
const DEVICE_IFACE = "org.bluez.Device1";
const BATTERY_IFACE = "org.bluez.Battery1";
<* Where the system bus socket lives on current distributions; the first that exists is used by `probe`. *>
const SYSTEM_BUS_SOCKET = "/run/dbus/system_bus_socket";
const SYSTEM_BUS_SOCKET_LEGACY = "/var/run/dbus/system_bus_socket";
<* How many commands one pass of the worker takes from the mailbox. *>
const usz COMMAND_BATCH = 8;
<* Poller tag of the bus socket; the wake-up has its own tag. *>
const usz BUS_TAG = 1;
<* Native sources the worker waits on: the bus socket only. *>
const usz POLL_CAPACITY = 2;

<* The one descriptor-level state of the backend. The bus is used only by the worker thread. *>
struct Bluez
{
	Allocator allocator;
	String bus_address; // "" for the system bus
	String root; // prefix for pseudo-files; "" for the real system
	Connection bus;
	bool dirty; // the object tree may have changed since it was last read
	BluetoothHub* hub; // where states and events go, valid while the worker runs
}

const Driver DRIVER = {
	.info = { "bluez", "BlueZ (org.bluez) over the D-Bus system bus", 10 },
	.id = bluetooth::Backend.BLUEZ,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

<* A system bus socket exists, or a bus address was given explicitly. *>
fn bool probe(Options* options)
{
	if (options.bus_address.len > 0) return true;
	return path::exists((Path)SYSTEM_BUS_SOCKET) || path::exists((Path)SYSTEM_BUS_SOCKET_LEGACY);
}

<*
 Checks that BlueZ answers on the bus, on the caller's thread and with a
 short-lived connection, so that a missing BlueZ is an error of `open` rather
 than an empty service. Then fills the capabilities.

 @return? error::UNAVAILABLE : "The bus is not reachable, or BlueZ is not running on it"
*>
fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	Connection probe_bus;
	probe_bus.init(allocator);
	defer probe_bus.free();
	open_bus(&probe_bus, options.bus_address)!;
	bool owned = probe_bus.name_has_owner(BLUEZ_NAME)!;
	if (!owned) return error::UNAVAILABLE~;
	fill_capabilities(capabilities);
	Bluez* self = alloc::new(allocator, Bluez, {
		.allocator = allocator,
		.bus_address = bluetooth::copy_text(options.bus_address, allocator),
		.root = bluetooth::copy_text(options.root, allocator),
	});
	return self;
}

// What BlueZ can and cannot do through this backend. Each downgrade says why.
fn void fill_capabilities(Capabilities* capabilities) @private
{
	capabilities.init(availability::YES);
	capabilities.values[bluetooth::Cap.PAIR.ordinal] = {
		.reason = availability::Reason.DEGRADED,
		.note = "no pairing agent is registered; BlueZ answers the pairing itself or refuses",
	};
	capabilities.values[bluetooth::Cap.PAIRING_PROMPTS.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"bleu::dbus cannot export the pairing agent object yet"
	);
	capabilities.values[bluetooth::Cap.RFKILL_STATE.ordinal] = {
		.reason = availability::Reason.DEGRADED,
		.note = "read from /sys/class/rfkill; a kill switch that is not in sysfs is not seen",
	};
}

fn void destroy(Allocator allocator, void* state)
{
	Bluez* self = (Bluez*)state;
	if (self.bus_address.len > 0) alloc::free(allocator, self.bus_address.ptr);
	if (self.root.len > 0) alloc::free(allocator, self.root.ptr);
	alloc::free(allocator, self);
}

// Connects to the bus at `address`, or to the system bus when it is empty.
fn void? open_bus(Connection* bus, String address) @private
{
	if (address.len == 0) return bus.open_system();
	return bus.open_address(address);
}

<* The worker: connect, subscribe, then loop over the bus, the state and the mailbox until stopped. *>
fn void run(void* state, BluetoothHub* hub, Host{Request}* host)
{
	Bluez* self = (Bluez*)state;
	self.bus.init(self.allocator);
	defer self.bus.free();
	self.hub = hub;
	self.dirty = true;
	if (catch open_bus(&self.bus, self.bus_address))
	{
		bluetooth::publish_empty(hub);
		return;
	}
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), POLL_CAPACITY)) return;
	defer poller.free();
	if (catch subscribe(self))
	{
		bluetooth::publish_empty(hub);
		return;
	}
	Request[COMMAND_BATCH] commands;
	while (!host.stopping())
	{
		if (self.dirty)
		{
			self.dirty = false;
			refresh(self, hub);
		}
		// Replies that a synchronous call read while it waited are queued; deliver them before sleeping,
		// because no socket event may follow.
		if (catch self.bus.process()) break;
		if (!wait_for_bus(self, &poller)) break;
		if (catch self.bus.process()) break;
		usz count = host.mailbox().take_all(commands[..]);
		while (count > 0)
		{
			for (usz i = 0; i < count; i++) execute(self, &commands[i]);
			self.dirty = true;
			count = host.mailbox().take_all(commands[..]);
		}

	}
	// Finish what the bus still owes (pending replies fail as the bus closes), then say the service is gone.
	fail_queued(host);
	self.bus.close();
	bluetooth::publish_empty(hub);
}

// Waits until the bus socket is readable (or writable, while output waits) or a command arrives.
// Returns false when the socket cannot be watched any more.
fn bool wait_for_bus(Bluez* self, Poller* poller) @private
{
	int fd = self.bus.fd() ?? -1;
	if (fd < 0) return false;
	Interest interest;
	interest.readable = true;
	interest.writable = self.bus.has_pending_output();
	if (catch poller.add({ .handle = (Native)fd, .interest = interest, .tag = BUS_TAG })) return false;
	// A wait without a timeout returns on socket activity or on the wake-up; TIMEOUT cannot occur.
	if (catch poller.wait(time::FOREVER)) {}
	if (catch poller.remove(BUS_TAG)) return false;
	return true;
}

// Every request still queued fails as cancelled, because the service is stopping.
fn void fail_queued(Host{Request}* host) @private
{
	Request[COMMAND_BATCH] commands;
	usz count = host.mailbox().take_all(commands[..]);
	while (count > 0)
	{
		for (usz i = 0; i < count; i++)
		{
			commands[i].op.fail(error::CANCELLED);
			commands[i].op.release();
		}
		count = host.mailbox().take_all(commands[..]);
	}
}

// Subscribes to every BlueZ change that makes the state stale, and to device disconnections.
fn void? subscribe(Bluez* self) @private
{
	Proxy objects = proxy::for_object(&self.bus, BLUEZ_NAME, BLUEZ_ROOT, proxy::OBJECT_MANAGER_INTERFACE)!;
	SubscriptionId objects_watch = objects.watch_objects(&on_objects, self)!;
	SubscriptionId props_watch = objects.watch_properties(&on_properties, self, true)!;
	Match rule;
	rule.init(self.allocator);
	rule.with_type(MessageType.SIGNAL)!!;
	rule.with_sender(BLUEZ_NAME)!!;
	rule.with_interface(DEVICE_IFACE)!!;
	rule.with_member("Disconnected")!!;
	SubscriptionId disconnect_watch = self.bus.subscribe(rule, &on_disconnected, self)!;
}

fn void on_objects(void* context, ObjectChange* change)
{
	Bluez* self = (Bluez*)context;
	self.dirty = true;
}

fn void on_properties(void* context, PropertyChange* change)
{
	Bluez* self = (Bluez*)context;
	self.dirty = true;
}

// A device dropped its link. The reason and message are BlueZ's own words.
fn void on_disconnected(void* context, dbus::message::Message* signal)
{
	Bluez* self = (Bluez*)context;
	@pool()
	{
		if (try r = signal.reader())
		{
			if (try reason = r.read_string())
			{
				String address = bluetooth::address_of_device_path(signal.path, tmem) ?? "";
				bluetooth::emit(self.hub, bluetooth::EventKind.DEVICE_DISCONNECTED, address, reason);
			}
		}
	};
}
