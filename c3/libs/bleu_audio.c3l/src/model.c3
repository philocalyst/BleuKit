<*
 Audio devices, application streams and cards, as plain data.

 A shell's mixer needs three things: the output and input devices with their
 volume, mute and ports; the applications playing or recording through them; and
 the cards that offer profiles such as A2DP or headset. Everything here is a
 scalar, an enum, a typedef quantity, a string or a slice, so the state can be
 serialised and compared with no per-type code (ARCHITECTURE.md, rule 1).

 Volume is `bleu::unit::Gain` on the backend's own slider scale: 1.0 is the
 nominal 100 % position and values above it are over-amplification where the
 platform allows it. The scale is not a physical quantity; `audio::volume`
 converts it to amplitude and decibels for PulseAudio's cubic mapping.
*>
module bleu::audio;
import std::collections::maybe, bleu::unit, bleu::availability;

<* Direction of a device or stream: playback (OUTPUT) or capture (INPUT). *>
enum Flow : char
{
	OUTPUT,
	INPUT,
}

<*
 What a device is for, as the platform describes it. Values the platform does
 not distinguish are UNKNOWN; `INTERNAL` is a device built into the machine.
*>
enum FormFactor : char
{
	UNKNOWN,
	INTERNAL,            // built into the machine (PulseAudio "internal")
	SPEAKERS,
	HEADPHONES,
	HEADSET,             // headset with a microphone, or a hands-free unit
	HANDSET,
	MICROPHONE,          // capture-only device, including webcam microphones
	HDMI,                // HDMI or DisplayPort audio
	DIGITAL_PASSTHROUGH, // S/PDIF and other digital outputs
	LINE_LEVEL,
	CAR,
	TV,
	HIFI,
	PORTABLE,
	REMOTE_NETWORK,      // a network sink, such as a streaming receiver
}

<*
 How the device is attached. Bluetooth is a bus, not a form factor, so a
 Bluetooth headset is `HEADSET` on `BLUETOOTH`.
*>
enum Bus : char
{
	UNKNOWN,
	PCI,
	USB,
	BLUETOOTH,
	VIRTUAL, // software devices (null sinks, loopbacks, aggregate devices)
	OTHER,
}

<*
 Whether a port is connected. PulseAudio's `PA_PORT_AVAILABLE_*` values are
 0 unknown, 1 no, 2 yes; the enum keeps that order.
*>
enum PortAvailability : char
{
	UNKNOWN,
	NO,
	YES,
}

<* One selectable output or input of a device, such as "Headphones" or "HDMI 1". *>
struct Port
{
	String id;
	String description;
	PortAvailability availability;
	bool active;
}

<* An output or input device. `id` is stable across restarts of the server; use it in commands. *>
struct Device
{
	String id; // PulseAudio sink or source name, WASAPI endpoint ID, CoreAudio UID
	String name; // human-readable name for a list
	Flow flow;
	FormFactor form_factor;
	Bus bus;
	bool is_default; // the default device for its flow
	Gain[] volume; // one value per channel; empty when the device has no volume control
	Level level; // the loudest channel, clamped to nominal 100 % (a 0..1 view for simple sliders)
	Maybe{float} balance; // -1.0 (all left) .. +1.0 (all right); empty for mono or unbalanceable maps
	bool volume_is_hardware; // false when the server mixes the volume in software
	bool muted;
	Port[] ports; // empty when the platform has no ports
	String card_id; // owning card (PulseAudio); empty when there is none
}

<* An application's stream: playback (a sink input) or capture (a source output). *>
struct Stream
{
	String id; // PulseAudio index as text; WASAPI session instance identifier
	Flow flow;
	String app_name; // application.name, or the stream title when the app sets none
	String app_id; // desktop-file id, such as "org.mozilla.firefox"
	String app_icon; // freedesktop icon name
	String binary; // process executable name
	uint pid; // 0 when unknown
	String device_id; // device the stream is on; empty when none
	String media_name; // the stream's title, such as a song or a page
	Gain[] volume; // empty when the platform does not report it
	bool volume_writable;
	bool muted;
	bool corked; // paused by the server, not doing I/O
}

<* One profile a card offers, such as "a2dp-sink" or "headset-head-unit". *>
struct CardProfile
{
	String id;
	String description;
	bool available;
	uint sinks; // output devices it creates
	uint sources; // input devices it creates
}

<* A sound card. Profiles change which devices it exposes. *>
struct Card
{
	String id;
	String name;
	String active_profile; // empty when none is active
	CardProfile[] profiles;
}

<*
 The whole picture. Every snapshot is complete: a consumer that missed any
 number of intermediate states is resynchronised by the next one.
*>
struct State
{
	Device[] outputs;
	Device[] inputs;
	String default_output; // device id; empty when none
	String default_input;
	Stream[] streams;
	Card[] cards;
	bool mic_in_use; // a non-muted, non-corked application is recording from a microphone
	String degraded; // "" when every list was read; else what the server sent that could not be decoded, and what was skipped
}

<*
 A capability the backend can offer. Each one is `available` or carries the
 reason it is not, in the `Capabilities` map that `Audio.capability` reads.
*>
enum Cap : char
{
	DEVICE_VOLUME,    // set per-channel volume of a device
	DEVICE_BOOST,     // set a device volume above 100 %
	DEVICE_MUTE,
	INPUT_DEVICES,    // capture devices are listed and their volume is settable
	DEFAULT_SET,      // choose the default output or input
	PORTS,            // ports are listed
	PORT_SET,         // choose a device's active port
	CARD_PROFILES,    // cards and their profiles are listed
	CARD_PROFILE_SET, // choose a card's profile
	STREAMS_PLAYBACK, // application playback streams are listed
	STREAMS_RECORD,   // application recording streams are listed
	STREAM_VOLUME,    // set a stream's volume
	STREAM_MUTE,      // mute a stream
	STREAM_MOVE,      // move a stream to another output device
	MIC_IN_USE,       // the microphone indicator is derived
	EVENTS,           // device, stream and card changes arrive as events
	HW_VOLUME_FLAG,   // volume_is_hardware tells whether the server mixes in software
	PEAK_METER,       // level meters (not in v1 on any platform)
}

<*
 Something that happened. Re-read the state for the details: an event names
 the object and never carries its new volume.
*>
enum EventKind : char
{
	DEVICE_ADDED,
	DEVICE_REMOVED,
	DEVICE_CHANGED,
	DEFAULT_CHANGED,
	STREAM_ADDED,
	STREAM_REMOVED,
	STREAM_CHANGED,
	CARD_CHANGED,
	MIC_IN_USE_CHANGED,
}

<* A transient: `id` names the device, stream or card (empty for MIC_IN_USE_CHANGED and the default changes). *>
struct Event
{
	EventKind kind;
	Flow flow;
	String id;
}

<* Changes a shell asks for. Each one is a request: the world's change arrives through the state. *>
enum CommandKind : char
{
	REFRESH,
	SET_DEVICE_VOLUME,
	SET_DEVICE_MUTE,
	SET_DEFAULT,
	SET_STREAM_VOLUME,
	SET_STREAM_MUTE,
	MOVE_STREAM,
	SET_PORT,
	SET_CARD_PROFILE,
}

<*
 Which concrete mechanism provides the data. `AUTO` tries every backend of the
 platform in priority order.
*>
enum Backend : char
{
	AUTO,
	PULSE,     // Linux: PulseAudio native protocol (PulseAudio or PipeWire's pulse server)
	COREAUDIO, // macOS: CoreAudio HAL
	WASAPI,    // Windows: MMDevice, EndpointVolume and audio session APIs
}