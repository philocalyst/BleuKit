<*
 The COM interfaces the Windows backend calls: MMDevice (endpoints),
 EndpointVolume, the audio session manager and its controls, and the
 IMMNotificationClient callbacks. Layouts only; the behaviour is in
 windows_endpoints.c3 and windows_wasapi.c3.

 Every vtable lists its slots in order, IUnknown first (slots 0-2), because a
 call through a vtable is a call to a slot number. Slots the backend never
 calls are typed `void*` placeholders so the later ones land where they belong.

 Sources, each checked against two independent sources:
 - slot order: the windows crate 0.58.0 generated bindings
 (static.crates.io/crates/windows/windows-0.58.0.crate):
 Win32/Media/Audio/mod.rs (IMMDevice_Vtbl, IMMDeviceEnumerator_Vtbl,
 IMMDeviceCollection_Vtbl, IMMNotificationClient_Vtbl, IAudioSessionManager2_Vtbl
 with its base IAudioSessionManager_Vtbl, IAudioSessionEnumerator_Vtbl,
 IAudioSessionControl_Vtbl, IAudioSessionControl2_Vtbl, ISimpleAudioVolume_Vtbl),
 Win32/Media/Audio/Endpoints/mod.rs (IAudioEndpointVolume_Vtbl); and the
 bleu_win README (IMMDeviceEnumerator slots 3-7, IMMNotificationClient 3-7).
 - IIDs and CLSID: the same crate's define_interface! lines (for example
 IAudioEndpointVolume 5cdf2c82-841e-4546-9722-0cf74078229a, IAudioSessionManager2
 77aa99a0-1bd6-484f-8bc7-2c654c9a9b6f); the enumerator CLSID and IID are in the
 bleu_win README example.
 - property keys: the crate's PKEY_Device_FriendlyName (a45c254e-...-67d146a850e0,
 pid 14), PKEY_Device_DeviceDesc (pid 2), PKEY_AudioEndpoint_FormFactor
 (1da5d803-d492-4edd-8c23-e0c0ffee7f0e, pid 0).
 - EDataFlow, ERole, EndpointFormFactor, AudioSessionState and the VT_ values: the
 crate's Win32/Media/Audio/mod.rs and Win32/System/Variant/mod.rs.
 - CoTaskMemFree: ole32, the owner of every string COM hands back.
*>
module bleu::audio::windows_com @feat(WIN32) @link("ole32");
import std::os::win32, bleu::error, bleu::win::com, bleu::win::guid, bleu::win::hresult, bleu::win::text;

alias Hresult = hresult::Hresult;

const Guid IID_IMMDEVICE_ENUMERATOR    = guid::guid("a95664d2-9614-4f35-a746-de8db63617e6");
const Guid CLSID_MMDEVICE_ENUMERATOR   = guid::guid("bcde0395-e52f-467c-8e3d-c4579291692e");
const Guid IID_IMMNOTIFICATION_CLIENT  = guid::guid("7991eec9-7e89-4d85-8390-6c703cec60c0");
const Guid IID_IAUDIO_ENDPOINT_VOLUME  = guid::guid("5cdf2c82-841e-4546-9722-0cf74078229a");
const Guid IID_IAUDIO_SESSION_MANAGER2 = guid::guid("77aa99a0-1bd6-484f-8bc7-2c654c9a9b6f");
const Guid IID_IAUDIO_SESSION_CONTROL2 = guid::guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d");
const Guid IID_ISIMPLE_AUDIO_VOLUME    = guid::guid("87ce5498-68d6-44e5-9215-6da47ef883d8");

// EDataFlow (crate: eRender 0, eCapture 1, eAll 2).
const uint E_RENDER                   = 0;
const uint E_CAPTURE                  = 1;
// ERole (crate: eConsole 0, eMultimedia 1, eCommunications 2).
const uint E_CONSOLE                  = 0;
// DEVICE_STATE_ACTIVE (crate: 1); IMMDevice::GetState reports it for a usable endpoint.
const uint DEVICE_STATE_ACTIVE        = 1;
// AudioSessionState (crate: Inactive 0, Active 1, Expired 2).
const uint AUDIO_SESSION_STATE_ACTIVE = 1;
// STGM_READ for OpenPropertyStore.
const uint STGM_READ                  = 0;
// PROPVARIANT types (crate: VT_EMPTY 0, VT_UI4 19, VT_LPWSTR 31).
const ushort VT_EMPTY                 = 0;
const ushort VT_UI4                   = 19;
const ushort VT_LPWSTR                = 31;

// The endpoint's friendly name and its form factor (PROPERTYKEY values above).
const Guid PKEY_FMTID_DEVICE      = guid::guid("a45c254e-df1c-4efd-8020-67d146a850e0");
const Guid PKEY_FMTID_ENDPOINT    = guid::guid("1da5d803-d492-4edd-8c23-e0c0ffee7f0e");
const uint PKEY_PID_FRIENDLY_NAME = 14;
const uint PKEY_PID_FORM_FACTOR   = 0;

<* A PROPERTYKEY: a format identifier and a property id within it. *>
struct PropertyKey
{
	Guid fmtid;
	uint pid;
}

<*
 A PROPVARIANT, 24 bytes on x64 and ARM64: the type tag, three reserved words and a
 16-byte union whose first word holds a pointer or a 32-bit value.
*>
struct PropVariant
{
	ushort vt;
	ushort reserved1;
	ushort reserved2;
	ushort reserved3;
	ulong payload0;
	ulong payload1;
}

// Free memory COM allocated and handed back (a string from GetId, GetDisplayName ...).
extern fn void co_task_mem_free(void* memory) @cname("CoTaskMemFree");

// Release what a PROPVARIANT owns (the string of a VT_LPWSTR value).
extern fn Hresult prop_variant_clear(PropVariant* value) @cname("PropVariantClear");

// ---- IMMDeviceEnumerator, IMMDeviceCollection, IMMDevice ----

alias EnumAudioEndpointsFn = fn Hresult(void* self, uint data_flow, uint state_mask, IMMDeviceCollection** out);
alias GetDefaultEndpointFn = fn Hresult(void* self, uint data_flow, uint role, IMMDevice** out);
alias RegisterCallbackFn = fn Hresult(void* self, void* client);
alias GetDeviceFn = fn Hresult(void* self, Char16* id, IMMDevice** out);

struct IMMDeviceEnumeratorVtbl
{
	com::QueryInterfaceFn query_interface;
	com::AddRefFn add_ref;
	com::ReleaseFn release;
	EnumAudioEndpointsFn enum_audio_endpoints; // slot 3
	GetDefaultEndpointFn get_default_audio_endpoint; // slot 4
	GetDeviceFn get_device; // slot 5
	RegisterCallbackFn register_callback; // slot 6
	RegisterCallbackFn unregister_callback; // slot 7
}

struct IMMDeviceEnumerator
{
	IMMDeviceEnumeratorVtbl* vtbl;
}

alias GetCountFn = fn Hresult(void* self, uint* count);
alias ItemFn = fn Hresult(void* self, uint index, IMMDevice** out);

struct IMMDeviceCollectionVtbl
{
	com::QueryInterfaceFn query_interface;
	com::AddRefFn add_ref;
	com::ReleaseFn release;
	GetCountFn get_count; // slot 3
	ItemFn item; // slot 4
}

struct IMMDeviceCollection
{
	IMMDeviceCollectionVtbl* vtbl;
}

alias ActivateFn = fn Hresult(void* self, Guid* iid, uint context, PropVariant* params, void** out);
alias OpenPropertyStoreFn = fn Hresult(void* self, uint access, IPropertyStore** out);
alias GetIdFn = fn Hresult(void* self, Char16** id);
alias GetStateFn = fn Hresult(void* self, uint* state);

struct IMMDeviceVtbl
{
	com::QueryInterfaceFn query_interface;
	com::AddRefFn add_ref;
	com::ReleaseFn release;
	ActivateFn activate; // slot 3
	OpenPropertyStoreFn open_property_store; // slot 4
	GetIdFn get_id; // slot 5
	GetStateFn get_state; // slot 6
}

struct IMMDevice
{
	IMMDeviceVtbl* vtbl;
}

// ---- IPropertyStore ----

alias GetValueFn = fn Hresult(void* self, PropertyKey* key, PropVariant* value);

struct IPropertyStoreVtbl
{
	com::QueryInterfaceFn query_interface;
	com::AddRefFn add_ref;
	com::ReleaseFn release;
	void* get_count; // slot 3, unused
	void* get_at; // slot 4, unused
	GetValueFn get_value; // slot 5
	void* set_value; // slot 6, unused
	void* commit; // slot 7, unused
}

struct IPropertyStore
{
	IPropertyStoreVtbl* vtbl;
}

// ---- IAudioEndpointVolume ----

alias SetChannelScalarFn = fn Hresult(void* self, uint channel, float level, Guid* event_context);
alias GetChannelScalarFn = fn Hresult(void* self, uint channel, float* level);
alias SetMuteFn = fn Hresult(void* self, int muted, Guid* event_context);
alias GetMuteFn = fn Hresult(void* self, int* muted);

struct IAudioEndpointVolumeVtbl
{
	com::QueryInterfaceFn query_interface;
	com::AddRefFn add_ref;
	com::ReleaseFn release;
	void* register_control_change_notify; // slot 3, unused
	void* unregister_control_change_notify; // slot 4, unused
	GetCountFn get_channel_count; // slot 5
	void* set_master_volume_level; // slot 6, unused
	void* set_master_volume_level_scalar; // slot 7, unused
	void* get_master_volume_level; // slot 8, unused
	void* get_master_volume_level_scalar; // slot 9, unused
	void* set_channel_volume_level; // slot 10, unused
	SetChannelScalarFn set_channel_volume_level_scalar; // slot 11
	void* get_channel_volume_level; // slot 12, unused
	GetChannelScalarFn get_channel_volume_level_scalar; // slot 13
	SetMuteFn set_mute; // slot 14
	GetMuteFn get_mute; // slot 15
}

struct IAudioEndpointVolume
{
	IAudioEndpointVolumeVtbl* vtbl;
}

// ---- IAudioSessionManager2, IAudioSessionEnumerator ----

alias GetSessionEnumeratorFn = fn Hresult(void* self, IAudioSessionEnumerator** out);

struct IAudioSessionManager2Vtbl
{
	com::QueryInterfaceFn query_interface;
	com::AddRefFn add_ref;
	com::ReleaseFn release;
	void* get_audio_session_control; // slot 3 (IAudioSessionManager), unused
	void* get_simple_audio_volume; // slot 4 (IAudioSessionManager), unused
	GetSessionEnumeratorFn get_session_enumerator; // slot 5
}

struct IAudioSessionManager2
{
	IAudioSessionManager2Vtbl* vtbl;
}

alias GetSessionFn = fn Hresult(void* self, int index, IAudioSessionControl** out);
alias GetCountSignedFn = fn Hresult(void* self, int* count);

struct IAudioSessionEnumeratorVtbl
{
	com::QueryInterfaceFn query_interface;
	com::AddRefFn add_ref;
	com::ReleaseFn release;
	GetCountSignedFn get_count; // slot 3
	GetSessionFn get_session; // slot 4
}

struct IAudioSessionEnumerator
{
	IAudioSessionEnumeratorVtbl* vtbl;
}

// ---- IAudioSessionControl and IAudioSessionControl2 (the second extends the first) ----

alias GetStateSessionFn = fn Hresult(void* self, uint* state);
alias GetDisplayNameFn = fn Hresult(void* self, Char16** name);

struct IAudioSessionControlVtbl
{
	com::QueryInterfaceFn query_interface;
	com::AddRefFn add_ref;
	com::ReleaseFn release;
	GetStateSessionFn get_state; // slot 3
	GetDisplayNameFn get_display_name; // slot 4
	void* set_display_name; // slot 5, unused
	void* get_icon_path; // slot 6, unused
	void* set_icon_path; // slot 7, unused
	void* get_grouping_param; // slot 8, unused
	void* set_grouping_param; // slot 9, unused
	void* register_notification; // slot 10, unused
	void* unregister_notification; // slot 11, unused
}

struct IAudioSessionControl
{
	IAudioSessionControlVtbl* vtbl;
}

alias GetIdentifierFn = fn Hresult(void* self, Char16** id);
alias GetProcessIdFn = fn Hresult(void* self, uint* pid);
alias IsSystemSoundsFn = fn Hresult(void* self);

struct IAudioSessionControl2Vtbl
{
	com::QueryInterfaceFn query_interface;
	com::AddRefFn add_ref;
	com::ReleaseFn release;
	GetStateSessionFn get_state; // slot 3
	GetDisplayNameFn get_display_name; // slot 4
	void* set_display_name; // slot 5, unused
	void* get_icon_path; // slot 6, unused
	void* set_icon_path; // slot 7, unused
	void* get_grouping_param; // slot 8, unused
	void* set_grouping_param; // slot 9, unused
	void* register_notification; // slot 10, unused
	void* unregister_notification; // slot 11, unused
	GetIdentifierFn get_session_identifier; // slot 12
	GetIdentifierFn get_session_instance_identifier; // slot 13
	GetProcessIdFn get_process_id; // slot 14
	IsSystemSoundsFn is_system_sounds_session; // slot 15
}

struct IAudioSessionControl2
{
	IAudioSessionControl2Vtbl* vtbl;
}

// ---- ISimpleAudioVolume: the master volume and mute of one session ----

alias SetMasterVolumeFn = fn Hresult(void* self, float level, Guid* event_context);
alias GetMasterVolumeFn = fn Hresult(void* self, float* level);

struct ISimpleAudioVolumeVtbl
{
	com::QueryInterfaceFn query_interface;
	com::AddRefFn add_ref;
	com::ReleaseFn release;
	SetMasterVolumeFn set_master_volume; // slot 3
	GetMasterVolumeFn get_master_volume; // slot 4
	SetMuteFn set_mute; // slot 5
	GetMuteFn get_mute; // slot 6
}

struct ISimpleAudioVolume
{
	ISimpleAudioVolumeVtbl* vtbl;
}

// ---- IMMNotificationClient: the callbacks the system makes, implemented by the backend ----

alias OnStateChangedFn = fn Hresult(void* self, Char16* device_id, uint new_state);
alias OnDeviceFn = fn Hresult(void* self, Char16* device_id);
alias OnDefaultChangedFn = fn Hresult(void* self, uint data_flow, uint role, Char16* device_id);
alias OnPropertyChangedFn = fn Hresult(void* self, Char16* device_id, PropertyKey* key);

struct IMMNotificationClientVtbl
{
	com::QueryInterfaceFn query_interface;
	com::AddRefFn add_ref;
	com::ReleaseFn release;
	OnStateChangedFn on_device_state_changed; // slot 3
	OnDeviceFn on_device_added; // slot 4
	OnDeviceFn on_device_removed; // slot 5
	OnDefaultChangedFn on_default_device_changed; // slot 6
	OnPropertyChangedFn on_property_value_changed; // slot 7
}

<*
 Read a COM-allocated, NUL-terminated UTF-16 string into `allocator` and free
 the original. The result is "" for a null pointer.

 @return? error::INVALID_ARGUMENT : "the text is not valid UTF-16"
*>
fn String? take_wide(Allocator allocator, Char16* memory) @inline
{
	if (!memory) return "";
	defer co_task_mem_free(memory);
	return text::from_wide(allocator, (WString)memory) ?? "";
}