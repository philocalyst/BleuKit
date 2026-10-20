<*
 Unit conversions and classification for `/sys/class/power_supply`.

 The kernel reports µW, µWh, µA, µAh, µV and tenths of a degree, and spells
 states and chemistries as free text. This file turns those into Bleu's types.
 It is pure (no I/O) so it can be tested without a battery.

 Source: Documentation/ABI/testing/sysfs-class-power
 (https://docs.kernel.org/admin-guide/abi-testing-files.html), and the
 fallback order energy_* -> charge_* x voltage_now used by starship-battery
 0.10 (src/platform/linux).
*>
module bleu::battery::sysfs;
import std::time, bleu::unit, bleu::battery;

fn Kind kind_from_type(String type)
{
	switch (type)
	{
		case "Battery": return BATTERY;
		case "Mains":
		case "USB":
		case "USB_C":
		case "USB_PD":
		case "USB_DCP":
		case "USB_CDP":
		case "USB_ACA":
		case "Wireless": return MAINS;
		case "UPS": return UPS;
		default: return UNKNOWN;
	}
}

<* The kernel's `status` strings (power_supply_sysfs.c, POWER_SUPPLY_STATUS_TEXT). *>
fn ChargeState state_from_status(String status)
{
	switch (status)
	{
		case "Charging": return CHARGING;
		case "Discharging": return DISCHARGING;
		case "Not charging": return NOT_CHARGING;
		case "Full": return FULL;
		default: return UNKNOWN;
	}
}

<* The kernel's `technology` strings (POWER_SUPPLY_TECHNOLOGY_TEXT). *>
fn Chemistry chemistry_from_technology(String technology)
{
	switch (technology)
	{
		case "Li-ion": return LITHIUM_ION;
		case "Li-poly": return LITHIUM_POLYMER;
		case "LiFe": return LITHIUM_IRON_PHOSPHATE;
		case "NiCd": return NICKEL_CADMIUM;
		case "NiMH": return NICKEL_METAL_HYDRIDE;
		default: return UNKNOWN;
	}
}

<* µWh (or µAh x µV) to mWh. *>
fn MilliWattHour micro_to_milli(long micro) @inline => (MilliWattHour)(micro / 1000);

<*
 Charge in amp-hours times the battery voltage is energy. µAh x µV = pWh, so
 divide by 10^9 for mWh. Used when a battery reports charge_* instead of energy_*.
*>
fn MilliWattHour energy_from_charge(long micro_amp_hours, long micro_volts) @inline
{
	return (MilliWattHour)((double)micro_amp_hours * (double)micro_volts / 1.0e9);
}

<* Instantaneous µA at µV, as mW (µA x µV = pW; /10^9 = mW). *>
fn MilliWatt power_from_current(long micro_amps, long micro_volts) @inline
{
	return (MilliWatt)((double)micro_amps * (double)micro_volts / 1.0e9);
}

<* The kernel gives temperature in tenths of a degree Celsius. *>
fn Celsius celsius_from_tenths(long tenths) @inline => (Celsius)((float)tenths / 10.0f);

<*
 Time to empty/full from stored energy and flow, when the driver gave no
 estimate. Returns 0 when the flow is too small to extrapolate.
*>
fn Duration hours_at(long milli_watt_hours, long milli_watts)
{
	if (milli_watts <= 0) return time::DURATION_ZERO;
	return (Duration)((double)milli_watt_hours / (double)milli_watts * 3600.0 * 1.0e6);
}