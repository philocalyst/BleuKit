<*
 Battery and power-source state, as plain data.

 Everything a battery widget shows: the charge, whether the machine is on AC,
 how long until empty or full, and the health of each battery. Values the
 platform cannot tell are `Maybe` empties, never zero: 0 % is a fact, "unknown"
 is a different fact.
*>
module bleu::battery;
import std::time, std::collections::maybe, bleu::unit, bleu::availability;

enum Kind : char
{
	UNKNOWN,
	MAINS,      // wall adapter or USB-C charger
	BATTERY,
	UPS,
	PERIPHERAL, // mouse, keyboard, headset ...
}

enum ChargeState : char
{
	UNKNOWN,
	CHARGING,
	DISCHARGING,
	NOT_CHARGING, // plugged in, deliberately not charging (charge limit, hot battery)
	FULL,
	EMPTY,
}

enum Chemistry : char
{
	UNKNOWN,
	LITHIUM_ION,
	LITHIUM_POLYMER,
	LITHIUM_IRON_PHOSPHATE,
	LEAD_ACID,
	NICKEL_CADMIUM,
	NICKEL_METAL_HYDRIDE,
}

<*
 One power source. `id` is stable across snapshots (the kernel's name, the
 IOKit source id, the Windows device path) and is how events refer to it.
*>
struct Source
{
	String id;
	Kind kind;
	bool present;
	ChargeState state;
	Maybe{Level} charge; // state of charge
	Maybe{MilliWatt} power; // magnitude of the flow into (+) or out of (-) the battery
	Maybe{Duration} time_to_empty;
	Maybe{Duration} time_to_full;
	Maybe{MilliWattHour} energy; // stored right now
	Maybe{MilliWattHour} energy_full; // when full, today
	Maybe{MilliWattHour} energy_design; // when full, new
	Maybe{Level} health; // energy_full / energy_design
	Maybe{uint} cycles;
	Maybe{Celsius} temperature;
	Chemistry chemistry;
	String vendor;
	String model;
	String serial;
}

<*
 The whole picture. `on_mains` is the single answer to "am I plugged in?": it
 is true when any mains source is online, independent of which batteries exist.
*>
struct State
{
	bool on_mains;
	Source[] sources;
	// Rated wattage of the connected mains adapter. Empty when none is connected or the platform
	// does not report it (macOS reports it; Linux and Windows do not in v1). Added after v1 of the
	// model: the field is last so that positional initialisers written earlier keep their meaning.
	Maybe{uint} adapter_watts;
	// How the newest reading was obtained. AVAILABLE for a full reading; DEGRADED when some devices
	// could not be read and are left out of `sources`; BACKEND_STOPPED when the newest read failed,
	// and `sources` is the last good reading (never an empty state). Added after v1, last, like `adapter_watts`.
	Availability reading;
}

enum Cap : char
{
	CHARGE,
	TIME_ESTIMATE,
	POWER,
	HEALTH,
	CYCLES,
	TEMPERATURE,
	IDENTITY,
	PERIPHERALS,
}

enum EventKind : char
{
	SOURCE_ADDED,
	SOURCE_REMOVED,
	MAINS_CHANGED,
	STATE_CHANGED, // a source changed charge state (charging <-> discharging, full ...)
}

<*
 A transient: what changed. Re-read the state for the values. `source_id` names the source
 concerned, and is empty for MAINS_CHANGED.
*>
struct Event
{
	EventKind kind;
	String source_id;
}

enum Command : char
{
	REFRESH, // read the hardware now instead of waiting for the next poll
}

<* Which concrete mechanism provides the data. *>
enum Backend : char
{
	AUTO,
	SYSFS,  // Linux: /sys/class/power_supply
	UPOWER, // Linux: org.freedesktop.UPower
	IOKIT,  // macOS: IOPowerSources + IORegistry
	WIN32,  // Windows: GetSystemPowerStatus + battery IOCTLs
}