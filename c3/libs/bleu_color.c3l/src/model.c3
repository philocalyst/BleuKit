<*
 Colour temperature (night light), gamma ramps and software dimming, as plain data.

 A display's colour is changed by writing a gamma ramp: three tables, for red, green and blue,
 that map each value of the frame buffer to the value sent to the panel. This service writes
 ramps that warm the picture toward a colour temperature and scale its brightness. A ramp
 changes the picture, not the light: it is the software `GAMMA` mechanism that bleu::brightness
 reports and does not write (see README.md, "Integration with bleu::brightness").
*>
module bleu::color;
import std::collections::maybe, std::time, bleu::unit, bleu::availability, bleu::operation, bleu::rt;

<* An angle in degrees. *>
alias Degrees = double;

<* The temperature of full daylight and the temperature at night when no other value is set: Redshift's defaults. *>
const Kelvin DEFAULT_DAY = (Kelvin)6500;
const Kelvin DEFAULT_NIGHT = (Kelvin)4500;

<* The length of the change centred on each sunrise and sunset: 30 minutes, in microseconds. *>
const Duration DEFAULT_TRANSITION = (Duration)1_800_000_000;

<*
 How the temperature is chosen. MANUAL: only commands set it. SCHEDULE: it follows the sun at
 `latitude` and `longitude`. TIMES: it changes at fixed local times of day.
*>
enum Mode : char
{
	MANUAL,
	SCHEDULE,
	TIMES,
}

<*
 The schedule in force. Plain data, so a command can carry it to the worker.

 `day` and `night` are the temperatures of full daylight and of night. The temperature moves
 between them over `transition`, centred on each sunrise and sunset, with a smoothstep curve.
 For SCHEDULE, `latitude` (-90..90) and `longitude` (-180..180) are used. For TIMES, `sunrise`
 and `sunset` are local times of day in [0, 24 h) and the local UTC offset is taken from the OS.
 A zero-filled `Schedule` is MANUAL, so `{ }` means "no schedule".
*>
struct Schedule
{
	Mode mode;
	Degrees latitude;
	Degrees longitude;
	Duration sunrise;
	Duration sunset;
	Kelvin day;
	Kelvin night;
	Duration transition;
}

<*
 One display (an output, a monitor). `id` is stable across snapshots (the compositor's output
 name, the Windows display device name, the CoreGraphics display number) and is how commands
 name it. `name` is for people.
*>
struct Output
{
	String id;
	String name;
	Control control;
}

<*
 What the service can do with one display's gamma ramp.

 `gamma_supported`: the display accepts a ramp of `size` entries through this backend.
 `availability`: why not, when it does not, and a note otherwise.
 `temperature`: the colour temperature this service applies; empty means no change.
 `brightness`: the software dimming multiplier, 1.0 for none (the GAMMA mechanism of bleu::brightness).
 `active`: this service holds the display's ramp now, so the picture shows the change.
 `refused`: the display refused gamma control at the last attempt (the compositor sent `failed`):
 another client holds it, or the display has no gamma table. Commands on it return BUSY.
*>
struct Control
{
	bool gamma_supported;
	Availability availability;
	uint size;
	Maybe{Kelvin} temperature;
	Level brightness;
	bool active;
	bool refused;
}

<* The whole picture: every display the backend can see, and the schedule in force. *>
struct State
{
	Output[] outputs;
	Schedule schedule;
}

<*
 What the backend can do here, in general. Whether a particular display can do it is in `State`.
*>
enum Cap : char
{
	GAMMA_RAMP,      // the platform can write a gamma ramp at all
	SET_TEMPERATURE, // a colour temperature can be set
	SET_DIM,         // software dimming can be set
	SCHEDULE,        // the temperature can follow the sun or fixed times
}

<* A transient: what changed. Re-read the state for the values. *>
enum EventKind : char
{
	CONTROL_CHANGED,     // a display's gamma control was taken, refused, or lost
	TEMPERATURE_CHANGED, // the schedule moved the temperature
}

<* A transient. `output_id` is empty when the event concerns every display. *>
struct Event
{
	EventKind kind;
	String output_id;
}

<* Which concrete mechanism writes the ramps. `AUTO` tries the platform's backends in priority order. *>
enum Backend : char
{
	AUTO,
	WLR_GAMMA,    // Linux: zwlr_gamma_control_manager_v1 on a Wayland compositor
	WIN32_RAMP,   // Windows: SetDeviceGammaRamp on each display's device context
	COREGRAPHICS, // macOS: CGSetDisplayTransferByTable
}

<* Output ids are copied into fixed buffers so that commands are plain values. *>
const usz OUTPUT_ID_CAPACITY = 128;

enum CommandKind : char
{
	SET_TEMPERATURE,
	SET_DIM,
	RESET,
	SET_SCHEDULE,
}

<*
 A queued request. Plain data: the output id lives in `output` (empty means every output), and
 `operation` is the caller's operation, which the worker completes and releases.
*>
struct Command
{
	CommandKind kind;
	char[OUTPUT_ID_CAPACITY] output;
	usz output_len;
	Kelvin temperature;
	Level brightness;
	Schedule schedule;
	Operation{Applied}* operation;
}

<*
 The result of a command: how many displays it wrote, and the values now in force. Each is
 empty when the command does not concern it (`set_dim` has no temperature).
*>
struct Applied
{
	uint outputs;
	Maybe{Kelvin} temperature;
	Maybe{Level} brightness;
}

<* A request that finishes later. Its value says what was applied. *>
alias ApplyOperation = Operation{Applied};

<*
 Opens the Wayland connection for the wlr backend, and returns the connected descriptor. Used in
 place of `WAYLAND_DISPLAY` when set, so tests can attach a mock compositor. Runs on the worker
 thread, and the descriptor belongs to the service from then on.
*>
alias ConnectFn = fn rt::Native?(void* context);

<*
 How `open` finds and tunes a backend.

 `tick`: how often the schedule is evaluated (0 means `DEFAULT_TICK`).
 `connect`, `connect_context`: Linux only; null for the compositor named by the environment.
*>
struct Options
{
	Backend backend;
	Duration tick;
	ConnectFn connect;
	void* connect_context;
}

<* Default schedule evaluation interval: 10 s, which moves a 30-minute transition in 180 steps. *>
const Duration DEFAULT_TICK = (Duration)10_000_000;
