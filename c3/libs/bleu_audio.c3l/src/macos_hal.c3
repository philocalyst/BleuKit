<*
 Bindings to the CoreAudio HAL property API used by the macOS backend
 (AudioHardware.h, AudioHardwareBase.h, the HAL "AudioObject" functions).

 Plain C functions, so they are declared with `extern fn`; the framework is
 linked by the module attribute. Callbacks registered here run on a CoreAudio
 thread and must only enqueue (ARCHITECTURE.md, "Threads").

 Selector and scope values are the four-character codes. Source: the
 objc2-core-audio 0.3.2 crate, whose bindings are generated from Apple's SDK
 headers (src/generated/AudioHardware.rs: kAudioHardwarePropertyDevices =
 0x64657623 etc.; the same crate's AudioObject bindings give the scopes). The
 values spell the names ('dev#', 'dOut', 'uid ', 'volm', 'mute', 'bltn' ...),
 which is the one independent check available here; the numbers are not
 verified against a Mac (see the README).
*>
module bleu::audio::macos_hal @feat(DARWIN) @link("CoreAudio.framework");
import bleu::error;

alias OsStatus = int;
alias ObjectId = uint;

<* kAudioObjectSystemObject: the object that owns the device list and the defaults. *>
const ObjectId SYSTEM_OBJECT = 1;

const uint SCOPE_GLOBAL  = 0x676c6f62; // 'glob' kAudioObjectPropertyScopeGlobal
const uint SCOPE_INPUT   = 0x696e7074; // 'inpt' kAudioObjectPropertyScopeInput
const uint SCOPE_OUTPUT  = 0x6f757470; // 'outp' kAudioObjectPropertyScopeOutput
const uint ELEMENT_MAIN  = 0;         // kAudioObjectPropertyElementMain
const uint ELEMENT_LEFT  = 1;         // channel 1 of a device, the first of a stereo pair
const uint ELEMENT_RIGHT = 2;

const uint SELECTOR_DEVICES        = 0x64657623; // 'dev#'
const uint SELECTOR_DEFAULT_OUTPUT = 0x644f7574; // 'dOut'
const uint SELECTOR_DEFAULT_INPUT  = 0x64496e20; // 'dIn '
const uint SELECTOR_NAME           = 0x6c6e616d; // 'lnam' kAudioObjectPropertyName
const uint SELECTOR_UID            = 0x75696420; // 'uid ' kAudioDevicePropertyDeviceUID
const uint SELECTOR_VOLUME_SCALAR  = 0x766f6c6d; // 'volm'
const uint SELECTOR_MUTE           = 0x6d757465; // 'mute'
const uint SELECTOR_TRANSPORT      = 0x7472616e; // 'tran' kAudioDevicePropertyTransportType
const uint SELECTOR_RUNNING        = 0x676f6e65; // 'gone' kAudioDevicePropertyDeviceIsRunningSomewhere
const uint SELECTOR_STREAMS        = 0x73746d23; // 'stm#' kAudioDevicePropertyStreams

const uint TRANSPORT_BUILT_IN     = 0x626c746e; // 'bltn'
const uint TRANSPORT_USB          = 0x75736220; // 'usb '
const uint TRANSPORT_BLUETOOTH    = 0x626c7565; // 'blue'
const uint TRANSPORT_BLUETOOTH_LE = 0x626c6561; // 'blea'
const uint TRANSPORT_HDMI         = 0x68646d69; // 'hdmi'
const uint TRANSPORT_DISPLAY_PORT = 0x64707274; // 'dprt'
const uint TRANSPORT_VIRTUAL      = 0x76697274; // 'virt'
const uint TRANSPORT_AGGREGATE    = 0x67727570; // 'grup'
const uint TRANSPORT_PCI          = 0x70636920; // 'pci '
const uint TRANSPORT_AIRPLAY      = 0x61697270; // 'airp'
const uint TRANSPORT_THUNDERBOLT  = 0x7468756e; // 'thun'
const uint TRANSPORT_FIREWIRE     = 0x31333934; // '1394'

<* An AudioObjectPropertyAddress: which property of which scope and element. *>
struct PropertyAddress
{
	uint selector;
	uint scope;
	uint element;
}

<* AudioObjectPropertyListenerProc: called on a CoreAudio thread when a watched property changes. *>
alias ListenerFn = fn OsStatus(ObjectId object, uint count, PropertyAddress* addresses, void* client);

extern fn OsStatus audio_object_get_property_data_size(
	ObjectId object,
	PropertyAddress* address,
	uint qualifier_size,
	void* qualifier,
	uint* size
) @cname("AudioObjectGetPropertyDataSize");
extern fn OsStatus audio_object_get_property_data(
	ObjectId object,
	PropertyAddress* address,
	uint qualifier_size,
	void* qualifier,
	uint* size,
	void* data
) @cname("AudioObjectGetPropertyData");
extern fn OsStatus audio_object_set_property_data(
	ObjectId object,
	PropertyAddress* address,
	uint qualifier_size,
	void* qualifier,
	uint size,
	void* data
) @cname("AudioObjectSetPropertyData");
extern fn char audio_object_has_property(ObjectId object, PropertyAddress* address) @cname("AudioObjectHasProperty");
extern fn OsStatus audio_object_add_property_listener(
	ObjectId object,
	PropertyAddress* address,
	ListenerFn listener,
	void* client
) @cname("AudioObjectAddPropertyListener");
extern fn OsStatus audio_object_remove_property_listener(
	ObjectId object,
	PropertyAddress* address,
	ListenerFn listener,
	void* client
) @cname("AudioObjectRemovePropertyListener");

<* A HAL status other than noErr, as an error with the status in the detail. *>
fn fault hal_error(OsStatus status, String what) @private
{
	return error::raise(error::BACKEND_FAILURE, error::Domain.MACH, status, "%s failed with status %d", what, status);
}

<* Whether the object has the property. *>
fn bool has_property(ObjectId object, PropertyAddress address) => audio_object_has_property(object, &address) != 0;

<* The byte size of a property's value. *>
fn uint? property_size(ObjectId object, PropertyAddress address)
{
	uint size       = 0;
	OsStatus status = audio_object_get_property_data_size(object, &address, 0, null, &size);
	if (status != 0) return hal_error(status, "AudioObjectGetPropertyDataSize")~;
	return size;
}

<* Read a property's value into `out`, which must be as large as the value. *>
fn void? read_property(ObjectId object, PropertyAddress address, void* out, uint size)
{
	read_property_bytes(object, address, out, size)!;
}

<*
 Read a property's value into `out` (at most `size` bytes) and return how many
 bytes the HAL wrote. The value can be shorter than the size asked for when the
 property changed in between, so a caller that sized its buffer from an earlier
 query must use this count.
*>
fn uint? read_property_bytes(ObjectId object, PropertyAddress address, void* out, uint size)
{
	uint got        = size;
	OsStatus status = audio_object_get_property_data(object, &address, 0, null, &got, out);
	if (status != 0) return hal_error(status, "AudioObjectGetPropertyData")~;
	return got;
}

<* Write a property's value from `data`. *>
fn void? write_property(ObjectId object, PropertyAddress address, void* data, uint size)
{
	OsStatus status = audio_object_set_property_data(object, &address, 0, null, size, data);
	if (status != 0) return hal_error(status, "AudioObjectSetPropertyData")~;
}

<* A property holding one 32-bit unsigned value. *>
fn uint? read_u32(ObjectId object, PropertyAddress address)
{
	uint value = 0;
	read_property(object, address, &value, uint::size)!;
	return value;
}