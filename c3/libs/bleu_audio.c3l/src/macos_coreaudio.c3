<*
 The CoreAudio backend (macOS): devices, default devices, volume and mute, and
 device changes, through the HAL property API (macos_hal.c3).

 Not in v1: per-application streams (macOS has no per-application volume
 without a virtual driver), ports, card profiles, boost above 100 % and the
 private routes. Those capabilities say so.

 Threads: HAL listeners run on a CoreAudio thread. They only post a REFRESH
 command to the worker's mailbox; the worker re-reads the whole device list.
*>
module bleu::audio::macos_coreaudio @feat(DARWIN);
import std::time, bleu::availability, bleu::audio, bleu::error, bleu::observe, bleu::operation, bleu::unit, bleu::rt::poller, bleu::rt::mailbox, bleu::rt::worker, bleu::audio::macos_hal, bleu::audio::macos_devices;

const usz MAX_WATCHED        = 32;                  // devices whose volume, mute and running state are watched
const usz MAX_ADDRESSES      = 12;                  // listener addresses per device: 3 volume elements x 2 scopes, 2 mutes, 1 running state
const usz COMMAND_BATCH      = 16;
// The wait when the system listeners could not be registered: nothing but a command wakes the
// worker then, so the state is re-read this often instead.
const Duration FALLBACK_TICK = (Duration)1_000_000; // 1 s

<* One device's registered listeners, kept so they can be removed with the same addresses. *>
struct Watch
{
	macos_hal::ObjectId device;
	macos_hal::PropertyAddress[MAX_ADDRESSES] addresses;
	usz count;
}

<* What the backend remembers: the listener client (the worker's mailbox) and the watches. *>
struct CoreAudioBackend
{
	Mailbox{Command}* mailbox;
	Watch[MAX_WATCHED] watches;
	usz watch_count;
}

const Driver DRIVER = {
	.info = { "coreaudio", "CoreAudio HAL property API", 100 },
	.id = COREAUDIO,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.values[Cap.DEVICE_BOOST.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"the HAL volume range is 0..1; no boost through this API"
	);
	capabilities.values[Cap.PORTS.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"ports are not read on macOS in v1"
	);
	capabilities.values[Cap.PORT_SET.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"ports are not read on macOS in v1"
	);
	capabilities.values[Cap.CARD_PROFILES.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_OS,
		"card profiles exist on Linux only"
	);
	capabilities.values[Cap.CARD_PROFILE_SET.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_OS,
		"card profiles exist on Linux only"
	);
	capabilities.values[Cap.STREAMS_PLAYBACK.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"no per-application streams in v1 (a virtual driver would be needed)"
	);
	capabilities.values[Cap.STREAMS_RECORD.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"no per-application streams in v1 (a virtual driver would be needed)"
	);
	capabilities.values[Cap.STREAM_VOLUME.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"no per-application streams in v1"
	);
	capabilities.values[Cap.STREAM_MUTE.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"no per-application streams in v1"
	);
	capabilities.values[Cap.STREAM_MOVE.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"no per-application streams in v1"
	);
	capabilities.values[Cap.PEAK_METER.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"no level meters in v1"
	);
	capabilities.values[Cap.MIC_IN_USE.ordinal] = {
		availability::Reason.DEGRADED,
		"approximation: any input device running, including other apps and loopback drivers"
	};
	capabilities.values[Cap.HW_VOLUME_FLAG.ordinal] = {
		availability::Reason.DEGRADED,
		"reports whether the volume property exists; its meaning is not verified on hardware"
	};
	return alloc::new(allocator, CoreAudioBackend);
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

fn void run(void* state, AudioHub* hub, Host{Command}* host)
{
	CoreAudioBackend* backend = (CoreAudioBackend*)state;
	backend.mailbox = host.mailbox();
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1))
	{
		audio::publish_empty(hub);
		return;
	}
	defer poller.free();
	bool listening = add_system_listeners(backend);
	defer if (listening) remove_system_listeners(backend);
	Duration tick = listening ? time::FOREVER : FALLBACK_TICK;
	Command[COMMAND_BATCH] buffer;
	refresh(backend, hub);
	while (!host.stopping())
	{
		if (catch err = poller.wait(tick))
		{
			// TIMEOUT is the tick without listeners; any other failure ends the worker.
			if (err != TIMEOUT)
			{
				audio::publish_empty(hub);
				return;
			}
		}
		usz count = host.mailbox().take_all(buffer[..]);
		for (usz i = 0; i < count; i++)
		{
			execute_and_complete(&buffer[i]);
		}
		refresh(backend, hub);
	}
	remove_all_watches(backend);
}

// Run one queued command. A REFRESH has no completion; every other command is completed exactly once.
fn void execute_and_complete(Command* command) @private
{
	if (command.kind == CommandKind.REFRESH) return;
	Pending* done = command.done;
	if (catch err = execute(command))
	{
		(void)done.fail(err);
	}
	else
	{
		(void)done.succeed(true);
	}
	done.release();
}

<* Read the HAL and publish the state, and re-register the per-device listeners for the devices present. *>
fn void refresh(CoreAudioBackend* backend, AudioHub* hub) @private
{
	@pool()
	{
		macos_devices::HalDevice[]? devices = macos_devices::list_devices(tmem);
		if (catch err = devices)
		{
			audio::publish_empty(hub);
			return;
		}
		macos_hal::ObjectId default_output = macos_hal::read_u32(
			macos_hal::SYSTEM_OBJECT,
			{ macos_hal::SELECTOR_DEFAULT_OUTPUT, macos_hal::SCOPE_GLOBAL, macos_hal::ELEMENT_MAIN }
		) ?? 0;
		macos_hal::ObjectId default_input  = macos_hal::read_u32(
			macos_hal::SYSTEM_OBJECT,
			{ macos_hal::SELECTOR_DEFAULT_INPUT, macos_hal::SCOPE_GLOBAL, macos_hal::ELEMENT_MAIN }
		) ?? 0;
		// Listeners first, then the state: a change made after the listeners exist posts a refresh,
		// and one made before this read is in the state read below.
		sync_watches(backend, devices);
		Snapshot{State}* snapshot = hub.begin();
		macos_devices::devices_into(snapshot.allocator(), devices, default_output, default_input, &snapshot.value);
		snapshot.value.mic_in_use = any_input_running(devices);
		snapshot.value.cards = { };
		snapshot.value.streams = { };
		audio::publish_snapshot(hub, snapshot);
	};
}

// True when any input device reports that it is running.
fn bool any_input_running(macos_devices::HalDevice[] devices) @private
{
	foreach (&d : devices)
	{
		if (!d.has_input) continue;
		if ((macos_hal::read_u32(
			d.id,
			{ macos_hal::SELECTOR_RUNNING, macos_hal::SCOPE_GLOBAL, macos_hal::ELEMENT_MAIN }
		) ?? 0) != 0) return true;
	}
	return false;
}

// Watch the devices present and drop the watches of devices that went away. Nothing is
// touched when the same devices are present as last time: re-registering on every turn
// opened a window in which a change was not reported.
fn void sync_watches(CoreAudioBackend* backend, macos_devices::HalDevice[] devices) @private
{
	usz expected = devices.len < MAX_WATCHED ? devices.len : MAX_WATCHED;
	if (backend.watch_count == expected)
	{
		bool same = true;
		for (usz i = 0; i < expected && same; i++) same = backend.watches[i].device == devices[i].id;
		if (same) return;
	}
	remove_all_watches(backend);
	foreach (&d : devices)
	{
		if (backend.watch_count >= MAX_WATCHED) return;
		Watch* watch = &backend.watches[backend.watch_count];
		watch.device = d.id;
		watch.count = 0;
		add_watch_addresses(watch, d);
		backend.watch_count++;
		for (usz i = 0; i < watch.count; i++)
		{
			if (macos_hal::audio_object_add_property_listener(
				watch.device,
				&watch.addresses[i],
				&on_property,
				backend.mailbox
			) != 0)
			{
				// A device whose listener cannot be added is still listed; it just does not report its changes.
				watch.count = i;
				break;
			}
		}
	}
}

// The addresses a device is watched on: its volume and mute in each scope it has, and its running state.
fn void add_watch_addresses(Watch* watch, macos_devices::HalDevice* device) @private
{
	uint[2] scopes  = { macos_hal::SCOPE_OUTPUT, macos_hal::SCOPE_INPUT };
	bool[2] present = { device.has_output, device.has_input };
	for (usz s = 0; s < 2; s++)
	{
		if (!present[s]) continue;
		for (uint element = macos_hal::ELEMENT_MAIN; element <= macos_hal::ELEMENT_RIGHT; element++)
		{
			macos_hal::PropertyAddress address = { macos_hal::SELECTOR_VOLUME_SCALAR, scopes[s], element };
			if (macos_hal::has_property(device.id, address)) watch.addresses[watch.count++] = address;
		}
		macos_hal::PropertyAddress mute = { macos_hal::SELECTOR_MUTE, scopes[s], macos_hal::ELEMENT_MAIN };
		if (macos_hal::has_property(device.id, mute)) watch.addresses[watch.count++] = mute;
	}
	if (device.has_input)
	{
		macos_hal::PropertyAddress running = {
			macos_hal::SELECTOR_RUNNING,
			macos_hal::SCOPE_GLOBAL,
			macos_hal::ELEMENT_MAIN
		};
		if (macos_hal::has_property(device.id, running)) watch.addresses[watch.count++] = running;
	}
}

fn void remove_all_watches(CoreAudioBackend* backend) @private
{
	for (usz w = 0; w < backend.watch_count; w++)
	{
		Watch* watch = &backend.watches[w];
		for (usz i = 0; i < watch.count; i++)
		{
			if (macos_hal::audio_object_remove_property_listener(
				watch.device,
				&watch.addresses[i],
				&on_property,
				backend.mailbox
			) != 0)
			{
				// The listener was added a moment ago; a failure here leaves at most one stale listener.
			}
		}
	}
	backend.watch_count = 0;
}

fn bool add_system_listeners(CoreAudioBackend* backend) @private
{
	macos_hal::PropertyAddress[3] system = {
		{ macos_hal::SELECTOR_DEVICES, macos_hal::SCOPE_GLOBAL, macos_hal::ELEMENT_MAIN },
		{ macos_hal::SELECTOR_DEFAULT_OUTPUT, macos_hal::SCOPE_GLOBAL, macos_hal::ELEMENT_MAIN },
		{ macos_hal::SELECTOR_DEFAULT_INPUT, macos_hal::SCOPE_GLOBAL, macos_hal::ELEMENT_MAIN },
	};
	for (usz i = 0; i < 3; i++)
	{
		if (macos_hal::audio_object_add_property_listener(
			macos_hal::SYSTEM_OBJECT,
			&system[i],
			&on_property,
			backend.mailbox
		) != 0) return false;
	}
	return true;
}

fn void remove_system_listeners(CoreAudioBackend* backend) @private
{
	macos_hal::PropertyAddress[3] system = {
		{ macos_hal::SELECTOR_DEVICES, macos_hal::SCOPE_GLOBAL, macos_hal::ELEMENT_MAIN },
		{ macos_hal::SELECTOR_DEFAULT_OUTPUT, macos_hal::SCOPE_GLOBAL, macos_hal::ELEMENT_MAIN },
		{ macos_hal::SELECTOR_DEFAULT_INPUT, macos_hal::SCOPE_GLOBAL, macos_hal::ELEMENT_MAIN },
	};
	for (usz i = 0; i < 3; i++)
	{
		if (macos_hal::audio_object_remove_property_listener(
			macos_hal::SYSTEM_OBJECT,
			&system[i],
			&on_property,
			backend.mailbox
		) != 0)
		{
			// Removal of a listener that was registered at start cannot be acted on here.
		}
	}
}

<*
 HAL listener, on a CoreAudio thread. Only enqueues a REFRESH: no allocation
 beyond the mailbox's own, no state, no user code.
*>
fn macos_hal::OsStatus on_property(
	macos_hal::ObjectId object,
	uint count,
	macos_hal::PropertyAddress* addresses,
	void* client
)
{
	Mailbox{Command}* mailbox = (Mailbox{Command}*)client;
	if (catch err = mailbox.post({ .kind = CommandKind.REFRESH }))
	{
		// BUSY means the queue is full; the worker re-reads the state on every turn anyway.
	}
	return 0;
}

// Carry out one command on the HAL.
fn void? execute(Command* command) @private
{
	@pool()
	{
		switch (command.kind)
		{
			case CommandKind.SET_DEVICE_VOLUME: return set_volume(command)!;
			case CommandKind.SET_DEVICE_MUTE: return set_mute(command)!;
			case CommandKind.SET_DEFAULT: return set_default(command)!;
			case CommandKind.REFRESH:
			case CommandKind.SET_STREAM_VOLUME:
			case CommandKind.SET_STREAM_MUTE:
			case CommandKind.MOVE_STREAM:
			case CommandKind.SET_PORT:
			case CommandKind.SET_CARD_PROFILE: return error::UNSUPPORTED~;
		}
	};
}

// Set the channel volumes of a device, each in 0..1 (the HAL has no boost). Addresses the main
// control when the device has one, else its channels 1 and 2.
fn void? set_volume(Command* command) @private
{
	macos_devices::HalDevice[] devices = macos_devices::list_devices(tmem)!;
	macos_hal::ObjectId id             = macos_devices::id_of_uid(devices, command.target);
	if (id == 0) return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no device '%s'", command.target)~;
	foreach (gain : command.gains)
	{
		if (gain < (Gain)0.0f || gain > (Gain)1.0f) return error::raise(
			error::OUT_OF_RANGE,
			error::Domain.INTERNAL,
			0,
			"%f is outside 0..1 on this platform",
			(float)gain
		)~;
	}
	uint scope                      = macos_devices::scope_of(command.flow);
	macos_hal::PropertyAddress main = { macos_hal::SELECTOR_VOLUME_SCALAR, scope, macos_hal::ELEMENT_MAIN };
	if (macos_hal::has_property(id, main))
	{
		if (command.gains.len != 1) return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"the device has one channel"
		)~;
		float value = (float)command.gains[0];
		macos_hal::write_property(id, main, &value, float::size)!;
		return;
	}
	// Every channel is checked before the first write, so a refusal leaves the device as it was.
	for (usz i = 0; i < command.gains.len; i++)
	{
		if (!macos_hal::has_property(
			id,
			channel_address(scope, i)
		)) return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"the device has no channel %d",
			i + 1
		)~;
	}
	for (usz i = 0; i < command.gains.len; i++)
	{
		float value = (float)command.gains[i];
		macos_hal::write_property(id, channel_address(scope, i), &value, float::size)!;
	}
}

// Mute or unmute a device's main control.
fn void? set_mute(Command* command) @private
{
	macos_devices::HalDevice[] devices = macos_devices::list_devices(tmem)!;
	macos_hal::ObjectId id             = macos_devices::id_of_uid(devices, command.target);
	if (id == 0) return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no device '%s'", command.target)~;
	macos_hal::PropertyAddress mute = {
		macos_hal::SELECTOR_MUTE,
		macos_devices::scope_of(command.flow),
		macos_hal::ELEMENT_MAIN
	};
	if (!macos_hal::has_property(id, mute)) return error::UNSUPPORTED~;
	uint value = command.flag ? 1 : 0;
	macos_hal::write_property(id, mute, &value, uint::size)!;
}

// Make a device the default for its flow.
fn void? set_default(Command* command) @private
{
	macos_devices::HalDevice[] devices = macos_devices::list_devices(tmem)!;
	macos_hal::ObjectId id             = macos_devices::id_of_uid(devices, command.target);
	if (id == 0) return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no device '%s'", command.target)~;
	uint selector = command.flow == Flow.INPUT ? macos_hal::SELECTOR_DEFAULT_INPUT : macos_hal::SELECTOR_DEFAULT_OUTPUT;
	macos_hal::write_property(
		macos_hal::SYSTEM_OBJECT,
		{ selector, macos_hal::SCOPE_GLOBAL, macos_hal::ELEMENT_MAIN },
		&id,
		uint::size
	)!;
}

// The volume address of channel `index` (0 is the left channel) in `scope`.
fn macos_hal::PropertyAddress channel_address(uint scope, usz index) @private
{
	return { macos_hal::SELECTOR_VOLUME_SCALAR, scope, macos_hal::ELEMENT_LEFT + (uint)index };
}