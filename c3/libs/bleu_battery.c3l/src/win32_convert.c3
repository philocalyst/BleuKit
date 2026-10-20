<*
 Unit conversions and sentinel handling for the Windows battery interfaces.

 `GetSystemPowerStatus` reports bytes and seconds, and the battery class IOCTLs
 report mWh, mW and mV with their own unknown markers. This file maps those raw
 values into Bleu's types. It is pure (no I/O), so every host runs its tests.

 Sources for each constant are beside it: Microsoft Learn `ns-winbase-system_power_status`
 (SYSTEM_POWER_STATUS), `battery-information-str`, `battery-status-str`
 (BATTERY_INFORMATION, BATTERY_STATUS), and the `windows-sys` 0.59.0 constants of
 `Win32::System::Power` (batclass.h), which agree with them.
*>
module bleu::battery::win32;
import std::collections::maybe, bleu::battery, bleu::unit;

// SYSTEM_POWER_STATUS (winbase.h; Learn ns-winbase-system_power_status).
const uint AC_LINE_ONLINE          = 1;   // ACLineStatus: 0 offline, 1 online, 255 unknown
const uint SUMMARY_UNKNOWN_BYTE    = 255; // ACLineStatus, BatteryFlag, BatteryLifePercent: unknown
const uint SUMMARY_FLAG_CHARGING   = 8;   // BatteryFlag bit 8: charging
const uint SUMMARY_FLAG_NO_BATTERY = 128; // BatteryFlag bit 128: no system battery
const uint SUMMARY_UNKNOWN_SECONDS = 0xFFFFFFFF; // BatteryLifeTime: -1 when unknown or on AC (Learn)

// BATTERY_* bits and sentinels (batclass.h; Learn battery-information-str, battery-status-str).
const uint DEVICE_POWER_ON_LINE    = 1;          // PowerState: BATTERY_POWER_ON_LINE
const uint DEVICE_DISCHARGING      = 2;          // PowerState: BATTERY_DISCHARGING
const uint DEVICE_CHARGING         = 4;          // PowerState: BATTERY_CHARGING
const uint DEVICE_CAPACITY_RELATIVE = 0x40000000; // Capabilities: units are not mWh/mW (Learn)
const uint DEVICE_UNKNOWN_CAPACITY = 0xFFFFFFFF; // Capacity, FullChargedCapacity, DesignedCapacity
const uint DEVICE_UNKNOWN_RATE     = 0x80000000; // Rate, read as a signed LONG: -2147483648

<*
 Charge in [0, 1] from a GetSystemPowerStatus percent byte. 255 is unknown.
*>
fn Maybe{Level} summary_percent(uint raw)
{
	if (raw == SUMMARY_UNKNOWN_BYTE || raw > 100) return { };
	return maybe::value(unit::from_percent((float)raw));
}

<* A GetSystemPowerStatus duration in microseconds. 0xFFFFFFFF is unknown. *>
fn Maybe{Duration} summary_seconds(uint raw)
{
	if (raw == SUMMARY_UNKNOWN_SECONDS) return { };
	return maybe::value((Duration)((long)raw * 1_000_000));
}

<* Whether the mains line is online. Unknown counts as offline: nothing claims a charger. *>
fn bool summary_on_mains(uint ac_line_status) @inline => ac_line_status == AC_LINE_ONLINE;

<*
 Whether `BatteryFlag` describes a battery at all. 128 is "no system battery" and 255
 is "unknown"; neither describes a battery.
*>
fn bool summary_has_battery(uint battery_flag) @inline
{
	return battery_flag != SUMMARY_FLAG_NO_BATTERY && battery_flag != SUMMARY_UNKNOWN_BYTE;
}

<*
 The charge state of the summary battery. Charging comes from the flag bit; the rest
 from the mains line and the percent.
*>
fn ChargeState summary_state(uint battery_flag, bool on_mains, Maybe{Level} percent)
{
	bool charging = (battery_flag & SUMMARY_FLAG_CHARGING) != 0;
	bool known    = percent.has_value;
	bool full     = known && (float)percent.value >= 1.0f;
	bool empty    = known && (float)percent.value <= 0.0f;
	return battery::charge_state(on_mains || charging, charging, full, empty);
}

<*
 The charge state of one battery from its PowerState bits. Empty when the bits say
 neither charging nor discharging nor on line: the driver has not reported yet.
*>
fn ChargeState device_state(uint power_state, bool full, bool empty)
{
	bool on_line     = (power_state & DEVICE_POWER_ON_LINE) != 0;
	bool discharging = (power_state & DEVICE_DISCHARGING) != 0;
	bool charging    = (power_state & DEVICE_CHARGING) != 0;
	if (!on_line && !discharging && !charging) return UNKNOWN;
	return battery::charge_state(on_line || charging, charging, full, empty);
}

<* Whether the battery reports relative units. Its rates are per hour and its capacities are not mWh. *>
fn bool device_is_relative(uint capabilities) @inline => (capabilities & DEVICE_CAPACITY_RELATIVE) != 0;

<* A capacity in mWh; unknown when the driver reports the sentinel. *>
fn Maybe{MilliWattHour} device_capacity(uint raw)
{
	if (raw == DEVICE_UNKNOWN_CAPACITY) return { };
	return maybe::value((MilliWattHour)raw);
}

<*
 A flow in mW from BATTERY_STATUS.Rate: positive into the battery (charging), negative out
 of it (discharging). Learn battery-status-str says so in those words. Unknown when the
 driver reports the sentinel.
*>
fn Maybe{MilliWatt} device_rate(int raw)
{
	if ((uint)raw == DEVICE_UNKNOWN_RATE) return { };
	return maybe::value((MilliWatt)raw);
}
