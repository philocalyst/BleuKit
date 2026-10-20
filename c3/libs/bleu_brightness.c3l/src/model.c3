<*
 Display brightness, as plain data.

 A device (a panel, an external monitor, a keyboard) exposes one `Control` per
 mechanism that can move its light: the panel backlight, the OS's own panel
 call, DDC/CI, a software gamma ramp. Each control is reported separately, with
 its own readable and writable flags, its normalised `Level`, its raw device
 value and that value's range. Nothing is merged: the mechanism that produced a
 number is part of the number.
*>
module bleu::brightness;
import std::collections::maybe, std::time, bleu::availability, bleu::unit, bleu::ddc::transport, bleu::operation;

<*
 A way of moving a device's light. Each has its own failure modes and its own
 raw range, and none of them is a stand-in for another.
*>
enum Mechanism : char
{
	BACKLIGHT,    // The panel backlight as the OS exposes it: a sysfs class device, the panel IOCTL
	NATIVE,       // The OS's own call for a built-in panel that is not a backlight device (macOS DisplayServices)
	DDC,          // DDC/CI VCP 0x10 (luminance) on an external monitor
	GAMMA,        // A software ramp: it changes the picture, not the light
	OVERLAY,      // An app-drawn translucent window: software, reserved, not implemented
	KEYBOARD_LED, // A keyboard backlight LED
}

<* What a device is. The keyboard is not a display, but it is set the same way. *>
enum DeviceKind : char
{
	PANEL,    // A built-in panel
	EXTERNAL, // A monitor reached over DDC/CI or the OS's external path
	KEYBOARD, // A keyboard backlight
}

<*
 One mechanism on one device.

 `readable`: `level` and `raw` were read from the device on the last pass.
 `writable`: a request for this control can be carried out right now. When it
 is false, `availability` says why, and a request that names this control is
 refused with that reason.
 `raw` is the device's own number and `raw_min`..`raw_max` its range. Software
 controls have no device number: `raw` is empty and the range is 0..0.
*>
struct Control
{
	Mechanism mechanism;
	bool readable;
	bool writable;
	Availability availability;
	Maybe{Level} level;
	Maybe{long} raw;
	long raw_min;
	long raw_max;
}

<*
 A device and its controls. `id` is stable across snapshots (the kernel's
 connector or LED name, the Windows display device, the macOS display number)
 and is how requests name it. `controls` are in preference order: the order a
 request tries them in.
*>
struct Device
{
	String id;
	String name;
	DeviceKind kind;
	Control[] controls;
}

<* The whole picture: every device the backend can see. *>
struct State
{
	Device[] devices;
}

<*
 What the backend can do here, in general. Whether a particular device can do
 it is in `State`; a missing device is not a missing capability.
*>
enum Cap : char
{
	SET_BACKLIGHT,
	SET_NATIVE,
	SET_DDC,
	SET_GAMMA,
	SET_OVERLAY,
	SET_KEYBOARD_LED,
	TRANSITION, // a smooth ramp between two levels
}

<*
 How a request chooses among a device's controls.

 PREFER_HARDWARE: the writable hardware controls, best first. Only when no
 hardware control is writable does it use a software one, and the result says
 so in `Applied.mechanism`. A failing hardware write is an error.
 ALLOW_SOFTWARE: as PREFER_HARDWARE, and when a hardware write fails the
 request moves on to the software controls. The caller asked for that.
 EXACT: only the named mechanism. If it is not writable the request is refused;
 nothing else is tried.
*>
enum PolicyKind : char
{
	PREFER_HARDWARE,
	ALLOW_SOFTWARE,
	EXACT,
}

<* A request's choice of mechanism. `mechanism` is read only for `EXACT`. *>
struct Policy
{
	PolicyKind kind;
	Mechanism mechanism;
}

<*
 The result of one write: which mechanism carried it, what was asked for, what
 was written after rounding to the device's steps, and what the device reports
 after the write (empty when it could not be read back).
*>
struct Applied
{
	Mechanism mechanism;
	Level requested;
	Level applied;
	long raw;
	Maybe{Level} read_back;
}

<* A request that finishes later. Its value is what was written last. *>
alias SetOperation = Operation{Applied};

<*
 A transient: something changed. Re-read the state for the values.
*>
enum EventKind : char
{
	LEVEL_CHANGED, // a control's level differs from the previous state (keys, another client, our own writes)
	DEVICE_ADDED,
	DEVICE_REMOVED,
}

<* Transient event; `mechanism` is meaningful for `LEVEL_CHANGED` only. *>
struct Event
{
	EventKind kind;
	String device_id;
	Mechanism mechanism;
}

<* Device ids are copied into fixed buffers so that commands are plain values. *>
const usz DEVICE_ID_CAPACITY = 128;

enum CommandKind : char
{
	SET_LEVEL,
	REFRESH, // read the hardware now instead of waiting for the next pass
}

<*
 A queued request. Plain data: the device id lives in `device`, and `operation`
 is the caller's operation, which the worker completes and releases.
*>
struct Command
{
	CommandKind kind;
	char[DEVICE_ID_CAPACITY] device;
	usz device_len;
	Level level;
	Policy policy;
	Duration transition;
	SetOperation* operation;
}

<* Which concrete backend provides the state. `AUTO` tries the platform's backends in priority order. *>
enum Backend : char
{
	AUTO,
	LINUX, // logind or sysfs for backlights and keyboard LEDs; DDC/CI through /dev/i2c-N
	WIN32, // the panel IOCTL and dxva2 for external monitors
	MACOS, // DisplayServices for built-in panels
}

<*
 Opens the DDC/CI transport for a device path such as `<root>/dev/i2c-7`. Used in
 place of `/dev/i2c-N` when set, so tests can put a simulated monitor behind the
 real code path. Runs on the worker thread.
*>
alias OpenBusFn = fn Transport?(void* context, String device_path);

<*
 How `open` finds and tunes a backend.

 `poll`: how often the hardware is re-read (0 means `DEFAULT_POLL`).
 `transition_step`: time between the steps of a smooth transition (0 means `DEFAULT_TRANSITION_STEP`).
 `root`: prefix for kernel pseudo-files and device nodes, "" for the real system.
 `bus_address`: Linux: the D-Bus address that carries logind; "" means the system bus.
 `open_bus`, `open_bus_context`: Linux: replaces opening `/dev/i2c-N`; null for the real device.
*>
struct Options
{
	Backend backend;
	Duration poll;
	Duration transition_step;
	String root;
	String bus_address;
	OpenBusFn open_bus;
	void* open_bus_context;
}

<* Default re-read interval: quick enough for keyboard brightness keys, slow enough for DDC/CI. *>
const Duration DEFAULT_POLL = (Duration)2_000_000;

<* Default time between two steps of a smooth transition: 100 ms, a DDC/CI write takes most of that. *>
const Duration DEFAULT_TRANSITION_STEP = (Duration)100_000;

<* The request that changes nothing about the choice: hardware first, software only when there is no hardware. *>
const Policy DEFAULT_POLICY = { .kind = PREFER_HARDWARE, .mechanism = BACKLIGHT };

<* Whether `m` changes the picture rather than the light. *>
fn bool Mechanism.is_software(self) @inline => self == GAMMA || self == OVERLAY;

<*
 Ask for the mechanisms a request may use, hardware first. See `PolicyKind`.
*>
fn Policy prefer_hardware() @inline => DEFAULT_POLICY;

<* Hardware first, then software when a hardware write fails. See `PolicyKind`. *>
fn Policy allow_software() @inline => { .kind = ALLOW_SOFTWARE, .mechanism = BACKLIGHT };

<* Exactly `mechanism`, and nothing else. See `PolicyKind`. *>
fn Policy exact(Mechanism mechanism) @inline => { .kind = EXACT, .mechanism = mechanism };