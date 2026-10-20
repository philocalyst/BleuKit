<*
 Reading macOS power sources into a `State`.

 Two readers merge. IOPowerSources (`bleu::iokit::power`) gives one entry per
 source (the internal battery, a UPS) with its state and charge, and the time
 estimate. The IORegistry record of the `IOPMPowerSource` service gives what
 IOPowerSources does not: voltage, current, capacities, cycles and identity.
 Every key is cited where it is read. Unit rules live in `iokit_convert.c3`.


 Only the first internal battery takes the IORegistry record. On a Mac with two
 internal batteries the second one has no registry detail (lib README, "Not done").
*>
module bleu::battery::iokit @feat(DARWIN);
import std::collections::maybe, bleu::battery, bleu::cf, bleu::error, bleu::iokit, bleu::iokit::power, bleu::unit;

// Source: starship-battery 0.10.0 `src/platform/darwin/iokit/mod.rs` (IOPM_SERVICE_NAME); the
// XNU header names the class in `IOPMPowerSource`'s comment block (iokit/IOKit/pwr_mgt/IOPMPowerSource.h).
const ZString REGISTRY_CLASS = "IOPMPowerSource";

// IORegistry keys. XNU `iokit/IOKit/pwr_mgt/IOPM.h` gives the name in parentheses; the second
// name, where present, is the one starship-battery 0.10.0 reads. Where both are listed the
// reader prefers the first and falls back to the second.
const ZString KEY_EXTERNAL_CONNECTED   = "ExternalConnected";       // kIOPMPSExternalConnectedKey
const ZString KEY_IS_CHARGING          = "IsCharging";              // kIOPMPSIsChargingKey
const ZString KEY_FULLY_CHARGED        = "FullyCharged";            // kIOPMFullyChargedKey
const ZString KEY_VOLTAGE              = "Voltage";                 // kIOPMPSVoltageKey, mV
const ZString KEY_AMPERAGE             = "Amperage";                // kIOPMPSAmperageKey, mA, signed
const ZString KEY_DESIGN_CAPACITY      = "DesignCapacity";          // kIOPMPSDesignCapacityKey, mAh
const ZString KEY_MAX_CAPACITY         = "MaxCapacity";             // kIOPMPSMaxCapacityKey, mAh
const ZString KEY_CURRENT_CAPACITY     = "CurrentCapacity";         // kIOPMPSCurrentCapacityKey, mAh
const ZString KEY_RAW_MAX_CAPACITY     = "AppleRawMaxCapacity";     // starship (single source), preferred
const ZString KEY_RAW_CURRENT_CAPACITY = "AppleRawCurrentCapacity"; // starship (single source), preferred
const ZString KEY_CYCLE_COUNT          = "CycleCount";              // kIOPMPSCycleCountKey
const ZString KEY_MANUFACTURER         = "Manufacturer";            // kIOPMPSManufacturerKey
const ZString KEY_DEVICE_NAME          = "DeviceName";              // starship; XNU has "Model"
const ZString KEY_MODEL                = "Model";                   // kIOPMPSModelKey
const ZString KEY_BATTERY_SERIAL       = "BatterySerialNumber";     // starship; XNU has "Serial"
const ZString KEY_SERIAL               = "Serial";                  // kIOPMPSSerialKey
const ZString KEY_ADAPTER_WATTS        = "Watts";                   // kIOPMPSAdapterDetailsWattsKey

// Source: Apple IOKitUser `ps.subproj/IOPowerSources.c` (function body; fetched from
// apple-oss-distributions/IOKitUser). Returns seconds, negative when there is no estimate.
extern fn double io_ps_get_time_remaining_estimate() @cname("IOPSGetTimeRemainingEstimate");

<* A numeric value under `key` of a CoreFoundation dictionary. NOT_FOUND when absent or not a number. *>
fn long? number_of(CFTypeRef dictionary, ZString key)
{
	CFTypeRef value = power::description_value(dictionary, key);
	if (!value || cf::type_of(value) != cf::number_type_id()) return NOT_FOUND~;
	return cf::number_long(value);
}

<* `preferred` when the dictionary has it, else `fallback`. *>
fn long? number_either(CFTypeRef dictionary, ZString preferred, ZString fallback)
{
	if (try value = number_of(dictionary, preferred)) return value;
	return number_of(dictionary, fallback);
}

<* A string under `preferred`, else under `fallback`; "" when neither is present. *>
fn String text_either(CFTypeRef dictionary, ZString preferred, ZString fallback, Allocator allocator)
{
	String text = power::description_text(dictionary, preferred, allocator);
	if (text.len > 0) return text;
	return power::description_text(dictionary, fallback, allocator);
}

<*
 The IORegistry record of the first `IOPMPowerSource` service, owned by the caller.
 NOT_FOUND when the machine has none (a desktop Mac).

 @return? NOT_FOUND : "when no battery service is registered"
*>
fn cf::Ref? battery_record()
{
	iokit::ServiceIterator iterator = iokit::services_matching(REGISTRY_CLASS)!;
	defer iterator.close();
	if (try service = iterator.next())
	{
		defer service.close();
		return service.properties();
	}
	return NOT_FOUND~;
}

<*
 Read every power source into a `State` allocated from `allocator`.

 @return? error::BACKEND_FAILURE : "when IOPowerSources cannot produce a snapshot"
*>
fn State? read_all(Allocator allocator)
{
	@pool()
	{
		power::PowerSource[] supplies = power::read_power_sources(tmem)!;
		cf::Ref record                = { };
		if (try found = battery_record()) record = found;
		defer record.close();
		cf::Ref adapter = { };
		if (try details = power::external_adapter_details()) adapter = details;
		defer adapter.close();

		State state = { .on_mains = adapter.ptr != null };
		if (record.ptr != null && power::description_bool(record.ptr, KEY_EXTERNAL_CONNECTED)) state.on_mains = true;
		if (adapter.ptr != null)
		{
			if (try watts = number_of(adapter.ptr, KEY_ADAPTER_WATTS)) state.adapter_watts = maybe::value((uint)watts);
		}
		state.sources = alloc::new_array(allocator, Source, supplies.len);
		foreach (i, &supply : supplies)
		{
			state.sources[i] = source_from_supply(allocator, supply, i, record.ptr);
			if (supply.state == power::PowerSourceState.AC) state.on_mains = true;
		}
		if (record.ptr != null) merge_into_battery(state.sources, record.ptr, allocator);
		double seconds = io_ps_get_time_remaining_estimate();
		foreach (&source : state.sources)
		{
			if (source.kind == BATTERY) apply_estimate(source, seconds);
		}
		return state;
	};
}

<*
 One `Source` from its IOPowerSources entry. The charge state needs the registry's
 `FullyCharged` flag, so the record is passed in (null when there is none).
*>
fn Source source_from_supply(Allocator allocator, power::PowerSource* supply, sz index, CFTypeRef record)
{
	String id = supply.name.len > 0 ? supply.name.copy(allocator) : string::tformat("power-source-%d", (int)index)
		.copy(allocator);
	Kind kind = UNKNOWN;
	switch (supply.type)
	{
		case "InternalBattery": kind = BATTERY;
		case "UPS": kind = UPS;
		default: kind = UNKNOWN;
	}
	Source source = { .id = id, .kind = kind, .present = supply.present };
	if (!supply.present) return source;
	bool fully_charged = record != null && power::description_bool(record, KEY_FULLY_CHARGED);
	source.state = battery::charge_state(
		supply.state == power::PowerSourceState.AC,
		supply.charging,
		fully_charged,
		supply.charge.is_zero()
	);
	source.charge = maybe::value(supply.charge);
	return source;
}

<*
 Give the first battery source the registry detail: energy, health, power, cycles and identity.
 Energy is the registry's capacity in mAh times its voltage; power is the magnitude of current
 times voltage, with its direction taken from the charge state.
*>
fn void merge_into_battery(Source[] sources, CFTypeRef record, Allocator allocator)
{
	foreach (&source : sources)
	{
		if (source.kind != BATTERY) continue;
		merge_registry(source, record, allocator);
		return;
	}
}

<* Fill one battery source from its IORegistry record. Keys that are absent leave their fields empty. *>
fn void merge_registry(Source* source, CFTypeRef record, Allocator allocator)
{
	long millivolts = 0;
	if (try v = number_of(record, KEY_VOLTAGE)) millivolts = v;
	if (try now = number_either(record, KEY_RAW_CURRENT_CAPACITY, KEY_CURRENT_CAPACITY))
	{
		source.energy = maybe::value(energy_from_capacity(now, millivolts));
	}
	if (try max = number_either(record, KEY_RAW_MAX_CAPACITY, KEY_MAX_CAPACITY))
	{
		source.energy_full = maybe::value(energy_from_capacity(max, millivolts));
	}
	if (try design = number_of(record, KEY_DESIGN_CAPACITY))
	{
		source.energy_design = maybe::value(energy_from_capacity(design, millivolts));
	}
	if (source.energy_full.has_value && source.energy_design.has_value)
	{
		source.health = battery::health_from(source.energy_full.value, source.energy_design.value);
	}
	if (try cycles = number_of(record, KEY_CYCLE_COUNT)) source.cycles = maybe::value((uint)cycles);
	if (try amps = number_of(record, KEY_AMPERAGE))
	{
		MilliWatt magnitude = flow_magnitude(amperage_from_registry(amps), millivolts);
		if (source.state == DISCHARGING) source.power = maybe::value(-magnitude);
		if (source.state == CHARGING) source.power = maybe::value(magnitude);
	}
	source.vendor = power::description_text(record, KEY_MANUFACTURER, allocator);
	source.model = text_either(record, KEY_DEVICE_NAME, KEY_MODEL, allocator);
	source.serial = text_either(record, KEY_BATTERY_SERIAL, KEY_SERIAL, allocator);
}

<* Time to empty while discharging, time to full while charging, from the system estimate. *>
fn void apply_estimate(Source* source, double seconds)
{
	if (source.state == DISCHARGING) source.time_to_empty = estimate_from_seconds(seconds);
	if (source.state == CHARGING) source.time_to_full = estimate_from_seconds(seconds);
}