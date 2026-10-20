<*
 Unit conversions and enum mappings for UPower device properties.

 UPower reports energy in Wh, power in W, time in seconds, and enumerates device
 types, states and technologies as integers. This file maps them to Bleu's types.
 It is pure (no D-Bus), so it runs on every host.

 Source for every enum and unit: the UPower D-Bus specification,
 `dbus/org.freedesktop.UPower.Device.xml` (https://gitlab.freedesktop.org/upower/upower
 /-/raw/master/dbus/org.freedesktop.UPower.Device.xml), cross-checked against the
 `upower_dbus` 0.3.2 proxy names and types. Unit rules are spec-only (single source
 for the units; see docs/research/battery_impl.md).
*>
module bleu::battery::upower;
import std::collections::maybe, std::time, bleu::battery, bleu::unit;

// Device `Type` values (spec: Type, u). 0 unknown, 1 line power, 2 battery, 3 UPS;
// everything above is some peripheral or device class.
const uint TYPE_UNKNOWN    = 0;
const uint TYPE_LINE_POWER = 1;
const uint TYPE_BATTERY    = 2;
const uint TYPE_UPS        = 3;

// Device `State` values (spec: State, u, valid for batteries).
const uint STATE_UNKNOWN           = 0;
const uint STATE_CHARGING          = 1;
const uint STATE_DISCHARGING       = 2;
const uint STATE_EMPTY             = 3;
const uint STATE_FULLY_CHARGED     = 4;
const uint STATE_PENDING_CHARGE    = 5;
const uint STATE_PENDING_DISCHARGE = 6;

// Device `Technology` values (spec: Technology, u).
const uint TECHNOLOGY_LITHIUM_ION          = 1;
const uint TECHNOLOGY_LITHIUM_POLYMER      = 2;
const uint TECHNOLOGY_LITHIUM_IRON         = 3;
const uint TECHNOLOGY_LEAD_ACID            = 4;
const uint TECHNOLOGY_NICKEL_CADMIUM       = 5;
const uint TECHNOLOGY_NICKEL_METAL_HYDRIDE = 6;

<* The `Kind` of a device, from its `Type`. Peripherals are every type above UPS. *>
fn Kind device_kind(uint type)
{
	switch (type)
	{
		case TYPE_LINE_POWER: return MAINS;
		case TYPE_BATTERY: return BATTERY;
		case TYPE_UPS: return UPS;
		case TYPE_UNKNOWN: return UNKNOWN;
		default: return PERIPHERAL;
	}
}

<*
 The charge state from UPower's `State`. "Pending charge" and "pending discharge" mean the
 battery is held at its current level (a charge limit, or a plan to discharge on mains):
 both map to NOT_CHARGING.
*>
fn ChargeState device_state(uint state)
{
	switch (state)
	{
		case STATE_CHARGING: return CHARGING;
		case STATE_DISCHARGING: return DISCHARGING;
		case STATE_EMPTY: return EMPTY;
		case STATE_FULLY_CHARGED: return FULL;
		case STATE_PENDING_CHARGE:
		case STATE_PENDING_DISCHARGE: return NOT_CHARGING;
		default: return UNKNOWN;
	}
}

<* The chemistry from UPower's `Technology`. *>
fn Chemistry technology(uint technology)
{
	switch (technology)
	{
		case TECHNOLOGY_LITHIUM_ION: return LITHIUM_ION;
		case TECHNOLOGY_LITHIUM_POLYMER: return LITHIUM_POLYMER;
		case TECHNOLOGY_LITHIUM_IRON: return LITHIUM_IRON_PHOSPHATE;
		case TECHNOLOGY_LEAD_ACID: return LEAD_ACID;
		case TECHNOLOGY_NICKEL_CADMIUM: return NICKEL_CADMIUM;
		case TECHNOLOGY_NICKEL_METAL_HYDRIDE: return NICKEL_METAL_HYDRIDE;
		default: return UNKNOWN;
	}
}

<* Energy in mWh from UPower's Wh (spec: Energy, EnergyFull, EnergyFullDesign are in Wh). *>
fn MilliWattHour energy_from_wh(double watt_hours) @inline => (MilliWattHour)(watt_hours * 1000.0);

<*
 Flow in mW from UPower's `EnergyRate`, which is in W and positive when DISCHARGING.
 Bleu's flow is positive into the battery, so the sign flips here (spec, EnergyRate).
*>
fn MilliWatt power_from_rate(double watts) @inline => (MilliWatt)(-watts * 1000.0);

<*
 A duration from UPower's TimeToEmpty or TimeToFull, in seconds. Zero means unknown
 (spec: "0 when unknown"), so it is empty.
*>
fn Maybe{Duration} duration_from_seconds(long seconds)
{
	if (seconds <= 0) return { };
	return maybe::value((Duration)(seconds * 1_000_000));
}

<* A charge in [0, 1] from UPower's Percentage (0..100). *>
fn Maybe{Level} charge_from_percentage(double percentage)
{
	if (!(percentage >= 0.0)) return { };
	return maybe::value(unit::from_percent((float)percentage));
}

<* A cycle count from ChargeCycles (i). -1 means unknown (spec). *>
fn Maybe{uint} cycles_from(long cycles)
{
	if (cycles < 0) return { };
	return maybe::value((uint)cycles);
}

<* A temperature from UPower's Temperature (degrees Celsius, spec). *>
fn Maybe{Celsius} temperature_from(double celsius) @inline => maybe::value((Celsius)celsius);

<*
 Sort sources by id, so every snapshot lists them in the same order and equal states
 compare equal. Insertion sort: a machine has a handful of devices.
*>
fn void sort_by_id(Source[] sources)
{
	for (sz i = 1; i < sources.len; i++)
	{
		Source key = sources[i];
		sz j       = i - 1;
		while (j >= 0 && sources[j].id.compare_to(key.id) > 0)
		{
			sources[j + 1] = sources[j];
			j--;
		}
		sources[j + 1] = key;
	}
}