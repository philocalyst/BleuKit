<*
 Unit conversions and charge-state rules for macOS power sources.

 IOPowerSources (through `bleu::iokit::power`) and the IORegistry record of
 `IOPMPowerSource` report mAh, mA, mV and seconds; this file turns those into
 Bleu's types. It is pure (no I/O) so it runs on every host.

 Sources for each rule are cited beside it. Two rules stay open and are NOT
 implemented here: the temperature unit (see docs/research/battery_impl.md,
 section 2) and the sign of `Amperage` (the flow direction comes from the
 charge state instead).
*>
module bleu::battery::iokit;
import std::time, std::collections::maybe, bleu::battery, bleu::unit;

<*
 Energy in mWh from a capacity in mAh at a voltage in mV. mAh x mV is µWh, so
 divide by 1000.

 Units: the IORegistry comments in XNU `iokit/IOKit/pwr_mgt/IOPMPowerSource.h`
 ("Capacity measured in mAh", "Voltage measured in mV"); starship-battery 0.10.0
 `src/platform/darwin/device.rs` (`milliampere_hour!` x `millivolt!`).
*>
fn MilliWattHour energy_from_capacity(long milliamp_hours, long millivolts) @inline
{
	return (MilliWattHour)(milliamp_hours * millivolts / 1000);
}

<*
 Magnitude in mW of a flow of `milliamps` at `millivolts`. mA x mV is µW, so
 divide by 1000. The sign is not taken from `milliamps`: see `charge_state`.
*>
fn MilliWatt flow_magnitude(int milliamps, long millivolts) @inline
{
	long amps = milliamps < 0 ? -(long)milliamps : (long)milliamps;
	return (MilliWatt)(amps * millivolts / 1000);
}

<*
 `Amperage` as the signed 32-bit value it is stored as. The registry hands the
 value over as a CFNumber whose low 32 bits are the kernel's `int`; truncating to
 `int` recovers the sign. A 64-bit read would show a large positive number for a
 negative current.

 Sources: XNU `iokit/Kernel/IOPMPowerSource.cpp` (`setAmperage` stores
 `OSNumber::withNumber(val, 32)`; `amperage()` returns `(int)unsigned32BitValue()`);
 starship-battery 0.10.0 `src/platform/darwin/iokit/power_source.rs` (reads an i32).
*>
fn int amperage_from_registry(long raw) @inline => (int)raw;

<*
 Time to empty or to full from IOPSGetTimeRemainingEstimate, which returns seconds.
 A negative or NaN value means "no estimate" (the function returns negative
 sentinels for "unlimited" and "unknown"; the exact values are in IOPowerSources.h,
 which was not read, so every negative value is treated as no estimate).

 Source: Apple IOKitUser `ps.subproj/IOPowerSources.c` (the function body returns
 `60 x minutes` in seconds); fetched from
 apple-oss-distributions/IOKitUser on GitHub.
*>
fn Maybe{Duration} estimate_from_seconds(double seconds)
{
	if (!(seconds >= 0.0)) return { };
	return maybe::value((Duration)(seconds * 1_000_000.0));
}
