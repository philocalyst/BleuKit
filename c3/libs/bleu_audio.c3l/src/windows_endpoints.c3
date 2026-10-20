<*
 Reading the Windows audio endpoints and their sessions into the model, and
 finding one endpoint or session to change it.

 Reference counting: every interface pointer obtained here is released on the
 same path that obtained it (`defer release_ref`). A COM call that fails is
 raised with the HRESULT in the detail; nothing is retried.

 Form factor values follow PKEY_AudioEndpoint_FormFactor (EndpointFormFactor
 in the crate: RemoteNetworkDevice 0 ... DigitalAudioDisplayDevice 9,
 UnknownFormFactor 10). Bus is not reported by the endpoint API, so it is UNKNOWN.
*>
module bleu::audio::windows_endpoints @feat(WIN32);
import std::collections::list, std::collections::maybe, bleu::audio, bleu::error, bleu::unit, bleu::win::com, bleu::win::com_ptr, bleu::win::errors, bleu::win::guid, bleu::win::hresult, bleu::win::process, bleu::win::text, bleu::audio::volume, bleu::audio::windows_com;

<* Release one reference held on a COM object. *>
fn void release_ref(void* object)
{
	if (!object) return;
	com::IUnknown* unknown = (com::IUnknown*)object;
	unknown.vtbl.release(unknown);
}

<* Ask a COM object for another interface. The returned pointer holds a reference. *>
fn hresult::Hresult query_ref(void* object, Guid iid, void** out)
{
	com::IUnknown* unknown = (com::IUnknown*)object;
	return unknown.vtbl.query_interface(unknown, &iid, out);
}

<* Create the device enumerator (MMDeviceEnumerator) that the endpoint calls go through. *>
fn windows_com::IMMDeviceEnumerator*? open_enumerator()
{
	com_ptr::Com{windows_com::IMMDeviceEnumerator} owned = com_ptr::co_create_instance{windows_com::IMMDeviceEnumerator}(
		windows_com::CLSID_MMDEVICE_ENUMERATOR,
		windows_com::IID_IMMDEVICE_ENUMERATOR
	)!;
	return owned.ptr;
}

<* The identifier of the default endpoint of a flow, copied into `allocator`; "" when none. *>
fn String default_id(Allocator allocator, windows_com::IMMDeviceEnumerator* enumerator, uint flow) @local
{
	windows_com::IMMDevice* device = null;
	hresult::Hresult hr = enumerator.vtbl.get_default_audio_endpoint(enumerator, flow, windows_com::E_CONSOLE, &device);
	if (hr.failed()) return "";
	defer release_ref(device);
	return endpoint_id(allocator, device) ?? "";
}

<* The endpoint's persistent identifier (IMMDevice::GetId), copied into `allocator`. *>
fn String? endpoint_id(Allocator allocator, windows_com::IMMDevice* device)
{
	Char16* raw         = null;
	hresult::Hresult hr = device.vtbl.get_id(device, &raw);
	if (hr.failed()) return errors::raise_hresult(hr, "windows_com::IMMDevice::GetId")~;
	return windows_com::take_wide(allocator, raw);
}

<* A property of an endpoint's property store. The caller clears the variant. *>
fn bool endpoint_property(windows_com::IMMDevice* device, windows_com::PropertyKey key, windows_com::PropVariant* value)
{
	windows_com::IPropertyStore* store = null;
	hresult::Hresult hr                = device.vtbl.open_property_store(device, windows_com::STGM_READ, &store);
	if (hr.failed()) return false;
	defer release_ref(store);
	value.vt = windows_com::VT_EMPTY;
	hr = store.vtbl.get_value(store, &key, value);
	return hr.succeeded();
}

<* The friendly name of an endpoint, copied into `allocator`; the endpoint id when the name is missing. *>
fn String endpoint_name(Allocator allocator, windows_com::IMMDevice* device, String fallback) @local
{
	windows_com::PropVariant value;
	if (!endpoint_property(
		device,
		{ windows_com::PKEY_FMTID_DEVICE, windows_com::PKEY_PID_FRIENDLY_NAME },
		&value
	)) return fallback.copy(allocator);
	defer windows_com::prop_variant_clear(&value);
	if (value.vt != windows_com::VT_LPWSTR) return fallback.copy(allocator);
	return windows_com::take_wide(allocator, (Char16*)value.payload0) ?? fallback;
}

// The form factor of an endpoint (PKEY_AudioEndpoint_FormFactor, a VT_UI4).
fn FormFactor form_factor_of(windows_com::IMMDevice* device) @local
{
	windows_com::PropVariant value;
	if (!endpoint_property(
		device,
		{ windows_com::PKEY_FMTID_ENDPOINT, windows_com::PKEY_PID_FORM_FACTOR },
		&value
	)) return UNKNOWN;
	defer windows_com::prop_variant_clear(&value);
	if (value.vt != windows_com::VT_UI4) return UNKNOWN;
	switch ((uint)value.payload0)
	{
		case 0: return REMOTE_NETWORK;
		case 1: return SPEAKERS;
		case 2: return LINE_LEVEL;
		case 3: return HEADPHONES;
		case 4: return MICROPHONE;
		case 5: return HEADSET;
		case 6: return HANDSET;
		case 7:
		case 8: return DIGITAL_PASSTHROUGH;
		case 9: return HDMI;
		default: return UNKNOWN;
	}
}

<* Activate an interface of an endpoint or session manager. The caller releases the result. *>
fn void? activate(windows_com::IMMDevice* device, Guid iid, void** out)
{
	hresult::Hresult hr = device.vtbl.activate(device, &iid, com::CLSCTX_ALL, null, out);
	if (hr.failed()) return errors::raise_hresult(hr, "windows_com::IMMDevice::Activate")~;
}

<* The channel volumes of an endpoint, one per channel, on the 0..1 scale. Empty when there is no control. *>
fn Gain[]? endpoint_volumes(Allocator allocator, windows_com::IMMDevice* device) @local
{
	windows_com::IAudioEndpointVolume* control = null;
	if (catch err = activate(device, windows_com::IID_IAUDIO_ENDPOINT_VOLUME, (void**)&control)) return { };
	defer release_ref(control);
	uint count = 0;
	if (control.vtbl.get_channel_count(control, &count).failed()) return { };
	Gain[] gains = alloc::new_array(allocator, Gain, count);
	for (uint i = 0; i < count; i++)
	{
		float level = 0.0f;
		if (control.vtbl.get_channel_volume_level_scalar(control, i, &level).failed()) return { };
		gains[i] = unit::gain(level, 1.0f);
	}
	return gains;
}

// Whether an endpoint is muted (false when the control cannot be read).
fn bool endpoint_muted(windows_com::IMMDevice* device) @local
{
	windows_com::IAudioEndpointVolume* control = null;
	if (catch err = activate(device, windows_com::IID_IAUDIO_ENDPOINT_VOLUME, (void**)&control)) return false;
	defer release_ref(control);
	int muted = 0;
	if (control.vtbl.get_mute(control, &muted).failed()) return false;
	return muted != 0;
}

<*
 The output or input devices of one flow, with volume and mute. Strings go into
 `allocator`.

 @return? error::BACKEND_FAILURE : "the endpoint list could not be read"
*>
fn Device[]? endpoints_of(
	Allocator allocator,
	windows_com::IMMDeviceEnumerator* enumerator,
	uint flow,
	String default_id
) @local
{
	windows_com::IMMDeviceCollection* collection = null;
	hresult::Hresult hr                          = enumerator.vtbl.enum_audio_endpoints(
		enumerator,
		flow,
		windows_com::DEVICE_STATE_ACTIVE,
		&collection
	);
	if (hr.failed()) return errors::raise_hresult(hr, "windows_com::IMMDeviceEnumerator::EnumAudioEndpoints")~;
	defer release_ref(collection);
	uint count = 0;
	hr = collection.vtbl.get_count(collection, &count);
	if (hr.failed()) return errors::raise_hresult(hr, "windows_com::IMMDeviceCollection::GetCount")~;
	Device[] devices = alloc::new_array(allocator, Device, count);
	for (uint i = 0; i < count; i++)
	{
		windows_com::IMMDevice* device = null;
		hr = collection.vtbl.item(collection, i, &device);
		if (hr.failed()) return errors::raise_hresult(hr, "windows_com::IMMDeviceCollection::Item")~;
		defer release_ref(device);
		String id      = endpoint_id(allocator, device)!;
		Gain[] volumes = endpoint_volumes(allocator, device) ?? { };
		devices[i] = {
			.id = id,
			.name = endpoint_name(allocator, device, id),
			.flow = flow == windows_com::E_CAPTURE ? INPUT : OUTPUT,
			.form_factor = form_factor_of(device),
			.bus = UNKNOWN,
			.is_default = id == default_id,
			.volume = volumes,
			.muted = endpoint_muted(device),
			.volume_is_hardware = false,
		};
		Device* made = &devices[i];
		made.level = volume::loudest(made.volume).nominal();
		if (made.volume.len == 2) made.balance = maybe::value(volume::stereo_balance(made.volume[0], made.volume[1]));
	}
	return devices;
}


<*
 Every audio session of every active endpoint of a flow, as streams. A session
 is inactive (corked) when its state is not ACTIVE. Strings go into `allocator`.
*>
fn void sessions_into(
	Allocator allocator,
	windows_com::IMMDeviceEnumerator* enumerator,
	uint flow,
	List{Stream}* out
) @local
{
	windows_com::IMMDeviceCollection* collection = null;
	if (enumerator.vtbl.enum_audio_endpoints(enumerator, flow, windows_com::DEVICE_STATE_ACTIVE, &collection)
		.failed()) return;
	defer release_ref(collection);
	uint count = 0;
	if (collection.vtbl.get_count(collection, &count).failed()) return;
	for (uint i = 0; i < count; i++)
	{
		windows_com::IMMDevice* device = null;
		if (collection.vtbl.item(collection, i, &device).failed()) continue;
		defer release_ref(device);
		String endpoint                             = endpoint_id(tmem, device) ?? "";
		windows_com::IAudioSessionManager2* manager = null;
		if (catch err = activate(device, windows_com::IID_IAUDIO_SESSION_MANAGER2, (void**)&manager)) continue;
		defer release_ref(manager);
		windows_com::IAudioSessionEnumerator* sessions = null;
		if (manager.vtbl.get_session_enumerator(manager, &sessions).failed()) continue;
		defer release_ref(sessions);
		int session_count = 0;
		if (sessions.vtbl.get_count(sessions, &session_count).failed()) continue;
		for (int s = 0; s < session_count; s++)
		{
			windows_com::IAudioSessionControl* control = null;
			if (sessions.vtbl.get_session(sessions, s, &control).failed()) continue;
			defer release_ref(control);
			if (try stream = session_stream(allocator, control, flow, endpoint)) out.push(stream);
		}
	}
}

// One session as a stream: identity from the control, levels from its simple volume interface.
fn Stream? session_stream(
	Allocator allocator,
	windows_com::IAudioSessionControl* control,
	uint flow,
	String endpoint
) @local
{
	windows_com::IAudioSessionControl2* control2 = null;
	if (query_ref(control, windows_com::IID_IAUDIO_SESSION_CONTROL2, (void**)&control2)
		.failed()) return error::UNSUPPORTED~;
	defer release_ref(control2);
	Stream stream    = {
		.flow = flow == windows_com::E_CAPTURE ? INPUT : OUTPUT,
		.device_id = endpoint.copy(allocator),
		.volume_writable = true
	};
	Char16* instance = null;
	if (control2.vtbl.get_session_instance_identifier(control2, &instance).succeeded())
	{
		stream.id = windows_com::take_wide(allocator, instance) ?? "";
	}
	uint pid = 0;
	if (control2.vtbl.get_process_id(control2, &pid).succeeded()) stream.pid = pid;
	uint state = 0;
	if (control.vtbl.get_state(control, &state)
		.succeeded()) stream.corked = state != windows_com::AUDIO_SESSION_STATE_ACTIVE;
	Char16* display = null;
	if (control.vtbl.get_display_name(control, &display).succeeded())
	{
		stream.app_name = windows_com::take_wide(allocator, display) ?? "";
	}
	if (stream.pid != 0)
	{
		String image = process::query_image_name(stream.pid, tmem) ?? "";
		stream.binary = file_name_of(allocator, image);
		if (stream.app_name.len == 0) stream.app_name = stream.binary;
	}
	if (control2.vtbl.is_system_sounds_session(control2).succeeded() && stream.app_name.len == 0)
	{
		stream.app_name = "System sounds".copy(allocator);
	}
	windows_com::ISimpleAudioVolume* simple = null;
	if (query_ref(control2, windows_com::IID_ISIMPLE_AUDIO_VOLUME, (void**)&simple).succeeded())
	{
		defer release_ref(simple);
		float level = 0.0f;
		if (simple.vtbl.get_master_volume(simple, &level)
			.succeeded()) stream.volume = alloc_gains(allocator, unit::gain(level, 1.0f));
		int muted = 0;
		if (simple.vtbl.get_mute(simple, &muted).succeeded()) stream.muted = muted != 0;
	}
	return stream;
}

// A one-channel volume in `allocator`: a session has a single master level.
fn Gain[] alloc_gains(Allocator allocator, Gain level) @local
{
	Gain[] gains = alloc::new_array(allocator, Gain, 1);
	gains[0] = level;
	return gains;
}

// The last path component of a Windows path, copied into `allocator`.
fn String file_name_of(Allocator allocator, String full) @local
{
	sz cut = 0;
	for (sz i = 0; i < full.len; i++)
	{
		if (full[i] == '\\' || full[i] == '/') cut = i + 1;
	}
	return full[cut:full.len - cut].copy(allocator);
}

<* Build the whole state: the endpoints of both flows, their defaults, and every session. *>
fn State? build_state(Allocator allocator, windows_com::IMMDeviceEnumerator* enumerator)
{
	State state;
	state.default_output = default_id(allocator, enumerator, windows_com::E_RENDER);
	state.default_input = default_id(allocator, enumerator, windows_com::E_CAPTURE);
	state.outputs = endpoints_of(allocator, enumerator, windows_com::E_RENDER, state.default_output)!;
	state.inputs = endpoints_of(allocator, enumerator, windows_com::E_CAPTURE, state.default_input)!;
	List{Stream} streams;
	streams.init(allocator);
	sessions_into(allocator, enumerator, windows_com::E_RENDER, &streams);
	sessions_into(allocator, enumerator, windows_com::E_CAPTURE, &streams);
	state.streams = streams.array_view();
	foreach (&stream : state.streams)
	{
		if (stream.flow == INPUT && !stream.corked && !stream.muted) state.mic_in_use = true;
	}
	return state;
}

<*
 The endpoint with identifier `id`, from the enumerator. The caller releases it.

 @return? error::INVALID_ARGUMENT : "the identifier is not text that UTF-16 can hold"
 @return? NOT_FOUND : "no endpoint has that identifier"
*>
fn windows_com::IMMDevice*? find_endpoint(windows_com::IMMDeviceEnumerator* enumerator, String id)
{
	text::WideZ? wide = text::to_wide(mem, id);
	if (catch err = wide) return error::raise(
		error::INVALID_ARGUMENT,
		error::Domain.WIN32,
		0,
		"endpoint id is not valid text"
	)~;
	defer wide.free();
	windows_com::IMMDevice* device = null;
	hresult::Hresult hr            = enumerator.vtbl.get_device(enumerator, (Char16*)wide.as_wstring(), &device);
	if (hr.failed()) return errors::raise_hresult(hr, "windows_com::IMMDeviceEnumerator::GetDevice")~;
	return device;
}

<* Set each channel of an endpoint to its level, or every channel to a single level. *>
fn void? set_endpoint_volume(windows_com::IMMDevice* device, Gain[] levels)
{
	windows_com::IAudioEndpointVolume* control = null;
	activate(device, windows_com::IID_IAUDIO_ENDPOINT_VOLUME, (void**)&control)!;
	defer release_ref(control);
	uint count = 0;
	if (control.vtbl.get_channel_count(control, &count)
		.failed()) return error::raise(error::BACKEND_FAILURE, error::Domain.WIN32, 0, "GetChannelCount failed")~;
	if (levels.len != 1 && levels.len != count) return error::raise(
		error::INVALID_ARGUMENT,
		error::Domain.WIN32,
		0,
		"%d levels for %d channels",
		levels.len,
		count
	)~;
	for (uint i = 0; i < count; i++)
	{
		Gain level          = levels.len == 1 ? levels[0] : levels[(sz)i];
		hresult::Hresult hr = control.vtbl.set_channel_volume_level_scalar(control, i, (float)level, null);
		if (hr.failed()) return errors::raise_hresult(hr, "SetChannelVolumeLevelScalar")~;
	}
}

<* Mute or unmute an endpoint. *>
fn void? set_endpoint_mute(windows_com::IMMDevice* device, bool muted)
{
	windows_com::IAudioEndpointVolume* control = null;
	activate(device, windows_com::IID_IAUDIO_ENDPOINT_VOLUME, (void**)&control)!;
	defer release_ref(control);
	hresult::Hresult hr = control.vtbl.set_mute(control, muted ? 1 : 0, null);
	if (hr.failed()) return errors::raise_hresult(hr, "SetMute")~;
}

<*
 Find the session with instance identifier `instance` among the sessions of all
 endpoints of a flow, and return its simple volume interface (the caller releases it).
*>
fn windows_com::ISimpleAudioVolume*? find_session_volume(
	windows_com::IMMDeviceEnumerator* enumerator,
	uint flow,
	String instance
)
{
	windows_com::IMMDeviceCollection* collection = null;
	hresult::Hresult hr                          = enumerator.vtbl.enum_audio_endpoints(
		enumerator,
		flow,
		windows_com::DEVICE_STATE_ACTIVE,
		&collection
	);
	if (hr.failed()) return errors::raise_hresult(hr, "EnumAudioEndpoints")~;
	defer release_ref(collection);
	uint count = 0;
	collection.vtbl.get_count(collection, &count);
	for (uint i = 0; i < count; i++)
	{
		windows_com::IMMDevice* device = null;
		if (collection.vtbl.item(collection, i, &device).failed()) continue;
		defer release_ref(device);
		windows_com::IAudioSessionManager2* manager = null;
		if (catch err = activate(device, windows_com::IID_IAUDIO_SESSION_MANAGER2, (void**)&manager)) continue;
		defer release_ref(manager);
		windows_com::IAudioSessionEnumerator* sessions = null;
		if (manager.vtbl.get_session_enumerator(manager, &sessions).failed()) continue;
		defer release_ref(sessions);
		int session_count = 0;
		sessions.vtbl.get_count(sessions, &session_count);
		for (int s = 0; s < session_count; s++)
		{
			windows_com::IAudioSessionControl* control = null;
			if (sessions.vtbl.get_session(sessions, s, &control).failed()) continue;
			defer release_ref(control);
			if (try found = session_volume_if(control, instance)) return found;
		}
	}
	return NOT_FOUND~;
}

// The simple volume of a session whose instance identifier is `instance`; NOT_FOUND otherwise.
fn windows_com::ISimpleAudioVolume*? session_volume_if(
	windows_com::IAudioSessionControl* control,
	String instance
) @local
{
	windows_com::IAudioSessionControl2* control2 = null;
	if (query_ref(control, windows_com::IID_IAUDIO_SESSION_CONTROL2, (void**)&control2).failed()) return NOT_FOUND~;
	defer release_ref(control2);
	Char16* raw = null;
	if (control2.vtbl.get_session_instance_identifier(control2, &raw).failed()) return NOT_FOUND~;
	String id = windows_com::take_wide(tmem, raw) ?? "";
	if (id != instance) return NOT_FOUND~;
	windows_com::ISimpleAudioVolume* simple = null;
	if (query_ref(control2, windows_com::IID_ISIMPLE_AUDIO_VOLUME, (void**)&simple)
		.failed()) return error::UNSUPPORTED~;
	return simple;
}