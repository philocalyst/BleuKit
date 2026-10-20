<*
 Displays and monitors, as plain data.

 Everything a display settings panel shows: which outputs exist, where they sit in the
 layout, which mode, scale and rotation each one uses, and the modes it could use. Values
 the platform does not tell are `Maybe` empties, never zero or "none": a scale of 1.0 and an
 unknown scale are different facts.

 Coordinates are the operating system's logical layout, in logical pixels. Positions may be
 negative. Mode sizes are physical pixels. Refresh rates are in millihertz, so 59.94 Hz is
 59940 and is exact.
*>
module bleu::display;
import std::collections::maybe, std::collections::enummap, std::time, bleu::error, bleu::availability, bleu::observe, bleu::stream, bleu::operation, bleu::service;

<* A scale factor: 1.0, 1.25, 2.0 ... Fractional scales are exact in a double. *>
alias ScaleFactor = double;

<* Vertical refresh rate in millihertz; 59940 for 59.94 Hz. *>
alias RefreshMilliHz = uint;

<* A physical length in millimetres. *>
alias Millimetre = uint;

<*
 Output rotation and mirroring, in the order of the Wayland `wl_output.transform` enum, so the
 wire value and the ordinal are the same number. The FLIPPED values flip about the vertical
 axis first, then rotate.
*>
enum Transform : char
{
	NORMAL,
	R90,
	R180,
	R270,
	FLIPPED,
	FLIPPED_R90,
	FLIPPED_R180,
	FLIPPED_R270,
}

<*
 One video mode of an output. `preferred` is the mode the output advertises as its native one.
*>
struct Mode
{
	uint width;
	uint height;
	RefreshMilliHz refresh;
	bool preferred;
}

<*
 One output (monitor, panel, virtual display). `id` is stable across snapshots and across
 reconnects where the platform allows it: the connector name on Linux, the device path on
 Windows, the CoreGraphics display number on macOS. Events and configuration refer to it.
*>
struct Output
{
	String id;
	String name;
	String make;
	String model;
	String serial;
	String description;
	Maybe{Millimetre} width_mm;
	Maybe{Millimetre} height_mm;
	bool enabled;
	Maybe{bool} primary; // the output that owns the origin of the desktop, where the platform has one
	int x;
	int y;
	Maybe{Mode} current; // empty when the output is disabled
	Mode[] modes;
	Maybe{ScaleFactor} scale;
	Transform transform;
	Maybe{bool} adaptive_sync; // variable refresh, where the platform exposes it
	Maybe{bool} hdr; // high dynamic range turned on, where the platform exposes it
	Maybe{uint} colour_depth; // bits per colour channel, where the platform exposes it
	Maybe{String} mirror_of; // id of the output this one mirrors
	Maybe{ulong} edid_fingerprint; // identity from the raw EDID, where the bytes were read
}

<*
 The whole picture. `serial` is the compositor's configuration serial (Wayland output
 management); 0 where the platform has none.
*>
struct State
{
	Output[] outputs;
	uint serial;
}

<* What a backend can do here. Each one is `YES` or says why not. *>
enum Cap : char
{
	ENUMERATE,
	HOTPLUG,
	SET_LAYOUT,
	SET_MODE,
	SET_SCALE,
	SET_TRANSFORM,
	SET_ENABLED,
	TEST_ONLY,
	REVERT,
	PERSISTENT,
	SET_MIRROR,
	SET_HDR,
	SET_COLOUR_DEPTH,
	SET_ADAPTIVE_SYNC,
}

alias Capabilities = EnumMap{Cap, Availability};

<*
 What changed. `OUTPUT_*` describe an output coming, going or changing its properties; `REVERTED`
 says a change made with `APPLY_WITH_REVERT` was rolled back because nobody confirmed it.
*>
enum EventKind : char
{
	OUTPUT_ADDED,
	OUTPUT_REMOVED,
	OUTPUT_CHANGED,
	REVERTED,
}

<* A transient. `output_id` is empty for `REVERTED`. Re-read the state for the values. *>
struct Event
{
	EventKind kind;
	String output_id;
}

<*
 How a configuration is handled:
 TEST_ONLY asks whether the layout would work and changes nothing; APPLY makes it live;
 APPLY_WITH_REVERT makes it live and rolls it back unless `confirm` is called in time.
*>
enum ApplyMode : char
{
	TEST_ONLY,
	APPLY,
	APPLY_WITH_REVERT,
}

<*
 The desired state of one output. `mode` is read only when `enabled`. `scale` empty means the
 platform's own default scale, where the platform has a default.
*>
struct OutputChange
{
	String output_id;
	bool enabled;
	Mode mode;
	int x;
	int y;
	Transform transform;
	Maybe{ScaleFactor} scale;
}

<*
 A full desired layout: one entry per output the service reported. `persistent` asks the
 platform to keep the change across sessions and restarts; it is refused where the compositor
 owns that setting.
*>
struct Config
{
	OutputChange[] outputs;
	bool persistent;
}

<* The result of an accepted configuration. `live` is true once the layout is in effect. *>
struct ApplyResult
{
	ApplyMode mode;
	bool live;
	bool revert_armed;
}

alias ApplyOp = Operation{ApplyResult};

<* What a command asks the worker to do. *>
enum CommandKind : char
{
	REFRESH, // read the hardware now instead of waiting for the next event
	APPLY, // carry out `config`; complete `op`
	CONFIRM, // keep the change that is waiting for confirmation
}

<*
 A command for the worker. `config` slices live in the arena of `op`, which the command holds a
 reference to until the worker completes it.
*>
struct Command
{
	CommandKind kind;
	ApplyOp* op;
	Config config;
	ApplyMode mode;
	Duration revert_after;
}

<* Which concrete mechanism provides the data. *>
enum Backend : char
{
	AUTO,
	WAYLAND,      // Linux: a Wayland compositor (wlr-output-management when offered, read-only otherwise)
	COREGRAPHICS, // macOS: CoreGraphics display list and configuration transactions
	WINDOWS,      // Windows: QueryDisplayConfig and SetDisplayConfig
}
