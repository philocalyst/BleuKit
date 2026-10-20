<*
 The IOBluetooth backend (macOS): the paired devices, and connect and
 disconnect of a whole device, through the public IOBluetooth classes.

 Reading: IOBluetooth publishes no change notifications for this list through
 the calls used here, so the worker re-reads `+[IOBluetoothDevice pairedDevices]`
 every `POLL_INTERVAL`. Connect and disconnect are the synchronous
 `openConnection` and `closeConnection` calls, run on the worker.

 Not in this build (declared as `Cap`s, not faked): controller power and
 discoverability, which only the private IOBluetoothPreference functions can
 set; pairing and the inquiry scan, which need an IOBluetoothDevicePair and an
 IOBluetoothDeviceInquiry delegate running on a run loop; trust, block, rename,
 unpair, battery and per-profile operations. See docs/research/bluetooth_impl.md.

 Sources: Apple IOBluetooth documentation, symbol lists in
 docs/research/bluetooth.md section 2.2 (AP-IOB), and blueutil (BLUEUTIL
 blueutil.m:919, 1165, 1196, 493, 533-541, read in the research spike).
*>
module bleu::bluetooth::iobluetooth @feat(DARWIN) @link("IOBluetooth.framework");
import std::time, bleu::availability, bleu::bluetooth, bleu::error, bleu::mach, bleu::objc,
	bleu::objc::foundation, bleu::operation, bleu::rt::poller, bleu::rt::worker, bleu::service;

<* How often the paired-device list is read again. *>
const Duration POLL_INTERVAL = (Duration)2_000_000;
<* Commands taken from the mailbox in one pass. *>
const usz COMMAND_BATCH = 8;
<* The RSSI value IOBluetooth reports when it cannot read the signal. *>
const char RSSI_UNREADABLE = 127;
<* The IOBluetooth class names and selectors this backend uses. *>
const ZString CLASS_DEVICE = "IOBluetoothDevice";
const ZString SELECTOR_PAIRED = "pairedDevices";
const ZString SELECTOR_ADDRESS = "addressString";
const ZString SELECTOR_NAME = "name";
const ZString SELECTOR_CONNECTED = "isConnected";
const ZString SELECTOR_PAIRED_FLAG = "isPaired";
const ZString SELECTOR_RSSI = "rawRSSI";
const ZString SELECTOR_DEVICE_WITH_ADDRESS = "deviceWithAddressString:";
const ZString SELECTOR_OPEN = "openConnection";
const ZString SELECTOR_CLOSE = "closeConnection";
const ZString SELECTOR_COUNT = "count";
const ZString SELECTOR_OBJECT_AT = "objectAtIndex:";

<* The state of the backend: only what the worker needs. *>
struct Session
{
	Allocator allocator;
	Duration poll;
}

const Driver DRIVER = {
	.info = { "iobluetooth", "IOBluetooth framework: paired devices, connect and disconnect", 10 },
	.id = IOBLUETOOTH,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// The IOBluetooth device class exists in this process.
fn bool probe(Options* options)
{
	return objc::class_named(CLASS_DEVICE) != null;
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	Availability private_call = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"the private IOBluetoothPreference calls are not part of this build"
	);
	Availability no_delegate = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"pairing and inquiry need an IOBluetooth delegate on a run loop, not built yet"
	);
	Availability no_public_api = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"no public IOBluetooth call for this operation"
	);
	capabilities.values[bluetooth::Cap.POWER.ordinal] = private_call;
	capabilities.values[bluetooth::Cap.DISCOVERABLE.ordinal] = private_call;
	capabilities.values[bluetooth::Cap.PAIRABLE.ordinal] = no_public_api;
	capabilities.values[bluetooth::Cap.DISCOVERY.ordinal] = no_delegate;
	capabilities.values[bluetooth::Cap.PAIR.ordinal] = no_delegate;
	capabilities.values[bluetooth::Cap.CANCEL_PAIRING.ordinal] = no_delegate;
	capabilities.values[bluetooth::Cap.PAIRING_PROMPTS.ordinal] = no_delegate;
	capabilities.values[bluetooth::Cap.PROFILE_CONNECT.ordinal] = no_public_api;
	capabilities.values[bluetooth::Cap.PROFILE_DISCONNECT.ordinal] = no_public_api;
	capabilities.values[bluetooth::Cap.TRUST.ordinal] = no_public_api;
	capabilities.values[bluetooth::Cap.BLOCK.ordinal] = no_public_api;
	capabilities.values[bluetooth::Cap.RENAME.ordinal] = no_public_api;
	capabilities.values[bluetooth::Cap.REMOVE.ordinal] = private_call;
	capabilities.values[bluetooth::Cap.BATTERY.ordinal] = no_public_api;
	capabilities.values[bluetooth::Cap.SERVICE_UUIDS.ordinal] = no_public_api;
	capabilities.values[bluetooth::Cap.MODALIAS.ordinal] = no_public_api;
	capabilities.values[bluetooth::Cap.RFKILL_STATE.ordinal] = no_public_api;
	Session* self = alloc::new(allocator, Session, { .allocator = allocator, .poll = POLL_INTERVAL });
	return self;
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

// The worker: read the paired devices, then wait for commands or the poll tick, and repeat.
fn void run(void* state, BluetoothHub* hub, Host{Request}* host)
{
	Session* self = (Session*)state;
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	Request[COMMAND_BATCH] commands;
	refresh(hub, self.allocator);
	while (!host.stopping())
	{
		// A timeout is the normal poll tick; a wake-up means a command is waiting.
		if (catch poller.wait(self.poll)) {}
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++) execute(&commands[i]);
		refresh(hub, self.allocator);
	}
	fail_queued(host);
	bluetooth::publish_empty(hub);
}

// Read the paired devices and publish them if they changed. An unreadable list is an empty one.
fn void refresh(BluetoothHub* hub, Allocator allocator) @private
{
	Snapshot{State}* snapshot = hub.begin();
	if (catch read_devices(snapshot.allocator(), &snapshot.value))
	{
		snapshot.value = { };
	}
	bluetooth::publish_changes(hub, snapshot);
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

// Complete one request. Only connect and disconnect exist in this build; the rest were refused by `create`.
fn void execute(Request* r) @private
{
	Operation{Done}* task = r.op;
	defer task.release();
	task.start();
	objc::@autorelease_pool()
	{
		switch (r.kind)
		{
			case bluetooth::Command.CONNECT:
				if (catch err = call_device(r.device, SELECTOR_OPEN, "openConnection"))
				{
					task.fail(err);
				}
				else
				{
					task.succeed(bluetooth::Done.DONE);
				}
			case bluetooth::Command.DISCONNECT:
				if (catch err = call_device(r.device, SELECTOR_CLOSE, "closeConnection"))
				{
					task.fail(err);
				}
				else
				{
					task.succeed(bluetooth::Done.DONE);
				}
			case bluetooth::Command.REFRESH:
				task.succeed(bluetooth::Done.DONE);
			default:
				task.fail(error::UNSUPPORTED);
		}
	};
}

// Looks up the device by address and sends it a connection selector; the IOReturn of the call is the outcome.
fn void? call_device(String address, ZString selector, ZString context) @private
{
	@pool()
	{
		String dashed = bluetooth::dashes_from_address(address, tmem);
		Obj text = foundation::from_string(dashed);
		ObjId device = objc::class_named(CLASS_DEVICE).send(ObjId, SELECTOR_DEVICE_WITH_ADDRESS, text.ptr);
		if (!device) return error::NOT_FOUND~;
		int code = (int)device.send(int, selector);
		mach::check(code, context)!;
	};
}

// The paired devices, as a state. Each device's name, link state and signal come from IOBluetooth.
fn void? read_devices(Allocator allocator, State* state) @private
{
	@pool()
	{
		ObjId paired = objc::class_named(CLASS_DEVICE).send(ObjId, SELECTOR_PAIRED);
		usz count = foundation::array_count(paired);
		List{Device} devices;
		devices.init(tmem);
		for (usz i = 0; i < count; i++)
		{
			ObjId item = foundation::array_at(paired, i);
			if (try device = device_from(item, allocator)) devices.push(device);
		}
		state.devices = alloc::clone_slice(allocator, devices.array_view());
		bluetooth::sort_devices(state.devices);
	};
}

// One paired device. A device without a readable address is skipped.
fn Device? device_from(ObjId item, Allocator allocator) @private
{
	if (try address = foundation::to_string(objc::ObjId_send_id(item, SELECTOR_ADDRESS), tmem))
	{
		return { };
	}
	return NOT_FOUND~;
}
