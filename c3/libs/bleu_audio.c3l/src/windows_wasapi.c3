<*
 The Windows audio backend: the MMDevice endpoints, their volume and mute, and
 the audio sessions of applications, through the Core Audio COM interfaces.

 Threads: the worker enters the multithreaded apartment (COM objects may be
 called from it without marshalling). The notification client implemented
 here (IMMNotificationClient) runs on system threads: it only posts a REFRESH
 to the worker's mailbox, never blocks, never registers or unregisters.

 Not in v1 (the capabilities say so): setting the default endpoint, which needs
 the undocumented IPolicyConfig interface (research 2.3.2); moving a session to
 another endpoint; boost above 1.0; peak meters. Volume changes have no
 callback here, so the worker re-reads the state once a second.
*>
module bleu::audio::wasapi @feat(WIN32);
import std::time, bleu::availability, bleu::audio, bleu::error, bleu::observe, bleu::operation, bleu::unit, bleu::rt::poller, bleu::rt::mailbox, bleu::rt::worker, bleu::win::com, bleu::win::com_shell, bleu::win::errors, bleu::win::hresult, bleu::audio::windows_com, bleu::audio::windows_endpoints;

const Duration POLL_INTERVAL = (Duration)1_000_000; // 1 s: how often volume changes are read
const usz COMMAND_BATCH = 16;

<* What the backend remembers: the mailbox the notification client posts to. *>
struct WasapiBackend
{
	Mailbox{Command}* mailbox;
}

alias NotifyShell = com_shell::Shell{windows_com::IMMNotificationClientVtbl};

const Driver DRIVER = {
	.info = { "wasapi", "Core Audio (MMDevice, EndpointVolume, audio sessions)", 100 },
	.id = WASAPI,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.values[Cap.DEFAULT_SET.ordinal] = availability::no(availability::Reason.UNSUPPORTED_BACKEND, "the default endpoint is set through an undocumented interface; not in v1");
	capabilities.values[Cap.DEVICE_BOOST.ordinal] = availability::no(availability::Reason.UNSUPPORTED_BACKEND, "endpoint volume is 0..1; no boost offered");
	capabilities.values[Cap.PORTS.ordinal] = availability::no(availability::Reason.UNSUPPORTED_OS, "ports are not read on Windows in v1");
	capabilities.values[Cap.PORT_SET.ordinal] = availability::no(availability::Reason.UNSUPPORTED_OS, "ports are not read on Windows in v1");
	capabilities.values[Cap.CARD_PROFILES.ordinal] = availability::no(availability::Reason.UNSUPPORTED_OS, "card profiles exist on Linux only");
	capabilities.values[Cap.CARD_PROFILE_SET.ordinal] = availability::no(availability::Reason.UNSUPPORTED_OS, "card profiles exist on Linux only");
	capabilities.values[Cap.STREAM_MOVE.ordinal] = availability::no(availability::Reason.UNSUPPORTED_BACKEND, "moving a session needs the undocumented policy interface");
	capabilities.values[Cap.PEAK_METER.ordinal] = availability::no(availability::Reason.UNSUPPORTED_BACKEND, "peak meters are not in v1");
	capabilities.values[Cap.HW_VOLUME_FLAG.ordinal] = { availability::Reason.DEGRADED, "every endpoint is reported as software volume: QueryHardwareSupport is not read in this version" };
	capabilities.values[Cap.MIC_IN_USE.ordinal] = { availability::Reason.DEGRADED, "a capture session that is active and not muted" };
	capabilities.values[Cap.EVENTS.ordinal] = { availability::Reason.DEGRADED, "device and session changes arrive as events; volume changes are read once a second" };
	return alloc::new(allocator, WasapiBackend);
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

fn void run(void* state, AudioHub* hub, Host{Command}* host)
{
	WasapiBackend* backend = (WasapiBackend*)state;
	backend.mailbox = host.mailbox();
	Apartment? apartment = com::enter(com::Model.MULTI_THREADED);
	if (catch err = apartment)
	{
		audio::publish_empty(hub);
		return;
	}
	defer apartment.leave();
	windows_com::IMMDeviceEnumerator*? opened = windows_endpoints::open_enumerator();
	if (catch err = opened)
	{
		audio::publish_empty(hub);
		return;
	}
	windows_com::IMMDeviceEnumerator* enumerator = opened;
	defer windows_endpoints::release_ref(enumerator);
	NotifyShell* shell = register_notifications(enumerator, backend);
	if (!shell) return;
	defer unregister_notifications(enumerator, shell);
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	Command[COMMAND_BATCH] buffer;
	refresh(enumerator, hub);
	while (!host.stopping())
	{
		if (catch poller.wait(POLL_INTERVAL)) {
			// TIMEOUT is the one-second tick that re-reads volumes.
		}
		usz count = host.mailbox().take_all(buffer[..]);
		for (usz i = 0; i < count; i++)
		{
			execute_and_complete(enumerator, &buffer[i]);
		}
		refresh(enumerator, hub);
	}
}

<* Read the endpoints and sessions and publish the result. *>
fn void refresh(windows_com::IMMDeviceEnumerator* enumerator, AudioHub* hub) @private
{
	@pool()
	{
		Snapshot{State}* snapshot = hub.begin();
		State? state = windows_endpoints::build_state(snapshot.allocator(), enumerator);
		if (catch err = state)
		{
			snapshot.release();
			audio::publish_empty(hub);
			return;
		}
		snapshot.value = state;
		audio::publish_snapshot(hub, snapshot);
	};
}

// Run one command. A REFRESH has no completion; every other command is completed exactly once.
fn void execute_and_complete(windows_com::IMMDeviceEnumerator* enumerator, Command* command) @private
{
	if (command.kind == CommandKind.REFRESH) return;
	Pending* done = command.done;
	if (catch err = execute(enumerator, command))
	{
		(void)done.fail(err);
	}
	else
	{
		(void)done.succeed(true);
	}
	done.release();
}

// Carry out one command through the endpoint and session interfaces.
fn void? execute(windows_com::IMMDeviceEnumerator* enumerator, Command* command) @private
{
	switch (command.kind)
	{
		case CommandKind.REFRESH:
			return;
		case CommandKind.SET_DEVICE_VOLUME:
			return set_device_volume(enumerator, command)!;
		case CommandKind.SET_DEVICE_MUTE:
			return set_device_mute(enumerator, command)!;
		case CommandKind.SET_STREAM_VOLUME:
			return set_stream_volume(enumerator, command)!;
		case CommandKind.SET_STREAM_MUTE:
			return set_stream_mute(enumerator, command)!;
		case CommandKind.SET_DEFAULT:
		case CommandKind.MOVE_STREAM:
		case CommandKind.SET_PORT:
		case CommandKind.SET_CARD_PROFILE:
			return error::UNSUPPORTED~;
	}
}

// Every level in 0..1 (no boost on this platform).
fn void? check_range(Gain[] levels) @private
{
	foreach (level : levels)
	{
		if (level < (Gain)0.0f || level > (Gain)1.0f) return error::raise(error::OUT_OF_RANGE, error::Domain.WIN32, 0, "%f is outside 0..1 on this platform", (float)level)~;
	}
}

fn void? set_device_volume(windows_com::IMMDeviceEnumerator* enumerator, Command* command) @private
{
	check_range(command.gains)!;
	windows_com::IMMDevice* device = windows_endpoints::find_endpoint(enumerator, command.target)!;
	defer windows_endpoints::release_ref(device);
	windows_endpoints::set_endpoint_volume(device, command.gains)!;
}

fn void? set_device_mute(windows_com::IMMDeviceEnumerator* enumerator, Command* command) @private
{
	windows_com::IMMDevice* device = windows_endpoints::find_endpoint(enumerator, command.target)!;
	defer windows_endpoints::release_ref(device);
	windows_endpoints::set_endpoint_mute(device, command.flag)!;
}

fn void? set_stream_volume(windows_com::IMMDeviceEnumerator* enumerator, Command* command) @private
{
	check_range(command.gains)!;
	if (command.gains.len != 1) return error::raise(error::INVALID_ARGUMENT, error::Domain.WIN32, 0, "a session has one level")~;
	windows_com::ISimpleAudioVolume* simple = windows_endpoints::find_session_volume(enumerator, flow_code(command.flow), command.target)!;
	defer windows_endpoints::release_ref(simple);
	hresult::Hresult hr = simple.vtbl.set_master_volume(simple, (float)command.gains[0], null);
	if (hr.failed()) return errors::raise_hresult(hr, "ISimpleAudioVolume::SetMasterVolume")~;
}

fn void? set_stream_mute(windows_com::IMMDeviceEnumerator* enumerator, Command* command) @private
{
	windows_com::ISimpleAudioVolume* simple = windows_endpoints::find_session_volume(enumerator, flow_code(command.flow), command.target)!;
	defer windows_endpoints::release_ref(simple);
	hresult::Hresult hr = simple.vtbl.set_mute(simple, command.flag ? 1 : 0, null);
	if (hr.failed()) return errors::raise_hresult(hr, "ISimpleAudioVolume::SetMute")~;
}

// The MMDevice data flow of a model flow.
fn uint flow_code(Flow flow) @inline => flow == Flow.INPUT ? windows_com::E_CAPTURE : windows_com::E_RENDER;

<* Register the notification client; the returned shell is what unregistering needs. Null on failure. *>
fn NotifyShell* register_notifications(windows_com::IMMDeviceEnumerator* enumerator, WasapiBackend* backend) @private
{
	NotifyShell* shell = com_shell::create{windows_com::IMMNotificationClientVtbl}(mem, &NOTIFY_TABLE, windows_com::IID_IMMNOTIFICATION_CLIENT, true, backend.mailbox);
	hresult::Hresult hr = enumerator.vtbl.register_callback(enumerator, shell);
	// The system holds its own reference once registered; ours is given up here.
	shell.vtbl.release(shell);
	if (hr.failed()) return null;
	return shell;
}

// Unregister and drop the system's reference, which frees the shell.
fn void unregister_notifications(windows_com::IMMDeviceEnumerator* enumerator, NotifyShell* shell) @private
{
	enumerator.vtbl.unregister_callback(enumerator, shell);
}

const windows_com::IMMNotificationClientVtbl NOTIFY_TABLE = {
	.query_interface = &com_shell::query_interface{windows_com::IMMNotificationClientVtbl},
	.add_ref = &com_shell::add_ref{windows_com::IMMNotificationClientVtbl},
	.release = &com_shell::release{windows_com::IMMNotificationClientVtbl},
	.on_device_state_changed = &on_device_state_changed,
	.on_device_added = &on_device_added,
	.on_device_removed = &on_device_removed,
	.on_default_device_changed = &on_default_device_changed,
	.on_property_value_changed = &on_property_value_changed,
};

// Ask the worker for a refresh. Runs on a system thread: only posts.
fn void request_refresh(void* self) @private
{
	NotifyShell* shell = com_shell::from_this{windows_com::IMMNotificationClientVtbl}(self);
	Mailbox{Command}* mailbox = (Mailbox{Command}*)shell.context;
	if (catch err = mailbox.post({ .kind = CommandKind.REFRESH })) {
		// BUSY means a refresh is already queued, which is all that is needed.
	}
}

fn hresult::Hresult on_device_state_changed(void* self, Char16* device_id, uint new_state)
{
	request_refresh(self);
	return (hresult::Hresult)hresult::S_OK;
}

fn hresult::Hresult on_device_added(void* self, Char16* device_id)
{
	request_refresh(self);
	return (hresult::Hresult)hresult::S_OK;
}

fn hresult::Hresult on_device_removed(void* self, Char16* device_id)
{
	request_refresh(self);
	return (hresult::Hresult)hresult::S_OK;
}

fn hresult::Hresult on_default_device_changed(void* self, uint data_flow, uint role, Char16* device_id)
{
	request_refresh(self);
	return (hresult::Hresult)hresult::S_OK;
}

fn hresult::Hresult on_property_value_changed(void* self, Char16* device_id, windows_com::PropertyKey* key)
{
	request_refresh(self);
	return (hresult::Hresult)hresult::S_OK;
}
