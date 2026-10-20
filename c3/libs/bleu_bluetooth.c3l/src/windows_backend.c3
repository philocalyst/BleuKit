<*
 The Win32 Bluetooth backend (Windows): the radios, the remembered devices,
 and removal of a device, through the bluetoothapis functions bound at run time
 (windows_api.c3).

 Reading: the Win32 functions announce no changes, so the worker re-reads the
 radios and devices every `POLL_INTERVAL`, and after each command.

 Not in this build, declared as `Cap`s: radio power (WinRT Radio.SetStateAsync),
 pairing (WinRT DeviceInformationCustomPairing with its PairingRequested event),
 inquiry, connect and disconnect (no Win32 call), per-profile service state,
 trust, block, rename, battery, RSSI and modalias. See docs/research/bluetooth_impl.md.

 Approximations that Win32 forces (each documented in the library README):
 a radio that Win32 enumerates is reported as powered; `discoverable`,
 `pairable` and `discovering` are reported false because they are not read;
 `paired` is the device's authenticated flag and `bonded` its remembered flag.
*>
module bleu::bluetooth::win32_backend @feat(WIN32);
import std::collections::list, std::os::win32, std::time, bleu::availability, bleu::bluetooth, bleu::dl, bleu::error, bleu::observe, bleu::operation, bleu::rt::poller, bleu::rt::worker, bleu::service, bleu::win::errors, bleu::win::text, bleu::bluetooth::win32_api;

<* How often the radios and devices are read again. *>
const Duration POLL_INTERVAL      = (Duration)5_000_000;
<* Commands taken from the mailbox in one pass. *>
const usz COMMAND_BATCH           = 8;
// The `size` member every Win32 structure carries: the byte size of the structure in x64 layout.
// BLUETOOTH_FIND_RADIO_PARAMS: one DWORD. BLUETOOTH_RADIO_INFO: DWORD, 8-byte address, 248 WCHAR, ULONG,
// USHORT x2 = 520 bytes. BLUETOOTH_DEVICE_SEARCH_PARAMS: DWORD, five BOOLs, UCHAR, pointer = 40 bytes.
// BLUETOOTH_DEVICE_INFO: DWORD, 8-byte address, ULONG, four BOOL-sized fields, two SYSTEMTIME, 248 WCHAR = 560 bytes.
const uint FIND_RADIO_PARAMS_SIZE = 4;
const uint RADIO_INFO_SIZE        = 520;
const uint SEARCH_PARAMS_SIZE     = 40;
const uint DEVICE_INFO_SIZE       = 560;
<* ERROR_SUCCESS: the Win32 functions return zero on success. *>
const uint ERROR_SUCCESS          = 0;

<* The state of the backend: the allocator for snapshots and the poll interval. *>
struct Session
{
	Allocator allocator;
	Duration poll;
}

const Driver DRIVER = {
	.info = { "win32", "Win32 Bluetooth functions (bluetoothapis.dll)", 10 },
	.id = WIN32,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// The functions can be bound here; `create` says whether they really are there.
fn bool probe(Options* options)
{
	return true;
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	win32_api::Api* api = win32_api::api()!;
	fill_capabilities(capabilities);
	Session* self = alloc::new(allocator, Session, { .allocator = allocator, .poll = POLL_INTERVAL });
	return self;
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

fn void fill_capabilities(Capabilities* capabilities) @private
{
	capabilities.init(availability::YES);
	Availability radio_power = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"radio power is WinRT Radio.SetStateAsync, not built in this version"
	);
	Availability pairing = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"pairing is WinRT custom pairing with its PairingRequested event, not built in this version"
	);
	Availability no_win32_call = availability::no(
		availability::Reason.UNSUPPORTED_OS,
		"the Win32 Bluetooth functions have no call for this operation"
	);
	Availability not_read = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"the Win32 functions used here do not report this"
	);
	capabilities.values[bluetooth::Cap.POWER.ordinal] = radio_power;
	capabilities.values[bluetooth::Cap.DISCOVERABLE.ordinal] = not_read;
	capabilities.values[bluetooth::Cap.PAIRABLE.ordinal] = not_read;
	capabilities.values[bluetooth::Cap.DISCOVERY.ordinal] = not_read;
	capabilities.values[bluetooth::Cap.PAIR.ordinal] = pairing;
	capabilities.values[bluetooth::Cap.CANCEL_PAIRING.ordinal] = pairing;
	capabilities.values[bluetooth::Cap.PAIRING_PROMPTS.ordinal] = pairing;
	capabilities.values[bluetooth::Cap.CONNECT.ordinal] = no_win32_call;
	capabilities.values[bluetooth::Cap.DISCONNECT.ordinal] = no_win32_call;
	capabilities.values[bluetooth::Cap.PROFILE_CONNECT.ordinal] = no_win32_call;
	capabilities.values[bluetooth::Cap.PROFILE_DISCONNECT.ordinal] = no_win32_call;
	capabilities.values[bluetooth::Cap.TRUST.ordinal] = no_win32_call;
	capabilities.values[bluetooth::Cap.BLOCK.ordinal] = no_win32_call;
	capabilities.values[bluetooth::Cap.RENAME.ordinal] = no_win32_call;
	capabilities.values[bluetooth::Cap.REMOVE.ordinal] = {
		.reason = availability::Reason.DEGRADED,
		.note = "BluetoothRemoveDevice forgets remembered devices only",
	};
	capabilities.values[bluetooth::Cap.BATTERY.ordinal] = not_read;
	capabilities.values[bluetooth::Cap.RSSI.ordinal] = not_read;
	capabilities.values[bluetooth::Cap.SERVICE_UUIDS.ordinal] = not_read;
	capabilities.values[bluetooth::Cap.MODALIAS.ordinal] = not_read;
	capabilities.values[bluetooth::Cap.RFKILL_STATE.ordinal] = not_read;
}

// The worker: read the radios and devices, then wait for commands or the poll tick, and repeat.
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
		if (catch poller.wait(self.poll))
		{
		}
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++) execute(&commands[i]);
		refresh(hub, self.allocator);
	}
	fail_queued(host);
	bluetooth::publish_empty(hub);
}

// Read the radios and devices and publish them if they changed. An unreadable system is an empty one.
fn void refresh(BluetoothHub* hub, Allocator allocator) @private
{
	Snapshot{State}* snapshot = hub.begin();
	if (catch read_state(snapshot.allocator(), &snapshot.value))
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

// Complete one request. Only removal exists in this build; the rest were refused by `create`.
fn void execute(Request* r) @private
{
	Task* task = r.op;
	defer task.release();
	task.start();
	if (catch err = perform(r))
	{
		task.fail(err);
	}
	else
	{
		task.succeed(bluetooth::Done.DONE);
	}
}

fn void? perform(Request* r) @private
{
	switch (r.kind)
	{
		case bluetooth::Command.REMOVE: return remove_device(r.device);
		case bluetooth::Command.REFRESH: return;
		default: return error::UNSUPPORTED~;
	}
}

// Forget a remembered device. Win32 reports failure as a Win32 error code.
fn void? remove_device(String address) @private
{
	win32_api::Api* api = win32_api::api()!;
	@pool()
	{
		ulong value = bluetooth::address_value(address)!;
		uint code   = api.remove_device(&value);
		if (code != ERROR_SUCCESS) return errors::raise_win32(code, "BluetoothRemoveDevice")~;
	};
}

// The radios and their remembered devices, as a state.
fn void? read_state(Allocator allocator, State* state) @private
{
	win32_api::Api* api = win32_api::api()!;
	@pool()
	{
		List{Adapter} adapters;
		adapters.init(tmem);
		List{Device} devices;
		devices.init(tmem);
		FindRadioParams params = { .size = FIND_RADIO_PARAMS_SIZE };
		void* radio            = null;
		void* find             = api.find_first_radio(&params, &radio);
		if (find != null)
		{
			defer api.find_radio_close(find);
			do
			{
				read_radio(api, radio, allocator, &adapters, &devices)!;
			} while (api.find_next_radio(find, &radio) != 0);
		}
		state.adapters = alloc::clone_slice(allocator, adapters.array_view());
		state.devices = alloc::clone_slice(allocator, devices.array_view());
		bluetooth::sort_adapters(state.adapters);
		bluetooth::sort_devices(state.devices);
	};
}

// One radio: its adapter record, then the devices it remembers. The handle is closed here.
fn void? read_radio(
	win32_api::Api* api,
	void* radio,
	Allocator allocator,
	List{Adapter}* adapters,
	List{Device}* devices
) @private
{
	defer win32::closeHandle((Win32_HANDLE)radio);
	RadioInfo info;
	info.size = RADIO_INFO_SIZE;
	uint code = api.get_radio_info(radio, &info);
	if (code != ERROR_SUCCESS) return errors::raise_win32(code, "BluetoothGetRadioInfo")~;
	String address = bluetooth::address_text(info.address, allocator);
	String name    = wide_text(info.name[..], allocator);
	adapters.push(
		{
			.address = address,
			.name = name,
			.display_name = name.len > 0 ? name : address,
			.powered = true,
		}
	);
	read_devices(api, radio, address, allocator, devices)!;
}

// Every device the radio remembers, authenticated or connected. Nothing is inquired.
fn void? read_devices(
	win32_api::Api* api,
	void* radio,
	String radio_address,
	Allocator allocator,
	List{Device}* devices
) @private
{
	DeviceSearchParams params = {
		.size = SEARCH_PARAMS_SIZE,
		.return_authenticated = 1,
		.return_remembered = 1,
		.return_connected = 1,
		.radio = radio,
	};
	DeviceInfo info;
	info.size = DEVICE_INFO_SIZE;
	void* find = api.find_first_device(&params, &info);
	// No device is an empty search; the Win32 functions signal that with a null handle.
	if (find == null) return;
	defer api.find_device_close(find);
	do
	{
		devices.push(device_from(&info, radio_address, allocator));
		info.size = DEVICE_INFO_SIZE;
	} while (api.find_next_device(find, &info) != 0);
}

fn Device device_from(DeviceInfo* info, String radio_address, Allocator allocator) @private
{
	String address = bluetooth::address_text(info.address, allocator);
	String name    = wide_text(info.name[..], allocator);
	return {
		.address = address,
		.adapter = radio_address,
		.name = name,
		.display_name = name.len > 0 ? name : address,
		.icon = bluetooth::icon_of(info.class_of_device, 0),
		.class_of_device = info.class_of_device,
		.paired = info.authenticated != 0,
		.bonded = info.remembered != 0,
		.connected = info.connected != 0,
	};
}

// A NUL-terminated UTF-16 buffer as text. Invalid text is empty.
fn String wide_text(Char16[] units, Allocator allocator) @private
{
	usz length = 0;
	while (length < units.len && units[length] != 0) length++;
	return text::from_wide_units(allocator, units[0:length]) ?? "";
}