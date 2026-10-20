<*
 The power-source and power-event vocabulary of IOPowerSources and IOPMLib, and the
 classifiers from raw values to it.

 This module is pure data and logic with no `@feat`, so every target compiles it
 and its `@test`s run on Linux. `power.c3` (Darwin only) re-exports the two enums
 as `power::PowerSourceState` and `power::PowerEvent`.

 Sources:
 * `kIOPSPowerSourceStateKey` values and the other key strings: IOPowerSources
   `IOPSKeys.h` in apple-oss-distributions/IOKitUser (`ps.subproj/`).
 * `kIOMessage*` codes: xnu `iokit/IOKit/IOMessage.h` (`iokit_common_msg`), and the
   Rust `io-kit-sys` 0.4.1 `src/keys.rs`.
*>
module bleu::iokit_power;

<* `kIOPSBatteryPowerValue`: a battery that is not on external power. *>
const ZString PS_BATTERY_POWER = "Battery Power";
<* `kIOPSACPowerValue`: on external power. *>
const ZString PS_AC_POWER      = "AC Power";
<* `kIOPSOffLineValue`: the source is off-line. *>
const ZString PS_OFF_LINE      = "Off Line";

<* Power-source state, from `kIOPSPowerSourceStateKey`. *>
enum PowerSourceState : char
{
	UNKNOWN, // the key is absent or has an unexpected value
	AC,      // on external power
	BATTERY, // drawing from the battery
	OFFLINE, // the source is off-line
}

<*
 Map the text of `kIOPSPowerSourceStateKey` to a state. An absent or unexpected
 value is `UNKNOWN`, which is never guessed from another key.

 @param text : "The state text; an empty string when the key is absent"
*>
fn PowerSourceState classify_state(String text)
{
	if (text == PS_AC_POWER) return AC;
	if (text == PS_BATTERY_POWER) return BATTERY;
	if (text == PS_OFF_LINE) return OFFLINE;
	return UNKNOWN;
}

<* `kIOMessageCanSystemSleep` (IOMessage.h): the system asks permission to sleep. Must be acknowledged. *>
const uint MSG_CAN_SYSTEM_SLEEP      = 0xE0000270;
<* `kIOMessageSystemWillSleep`: sleep is starting. Must be acknowledged. *>
const uint MSG_SYSTEM_WILL_SLEEP     = 0xE0000280;
<* `kIOMessageSystemWillNotSleep`: a previous sleep request was withdrawn. *>
const uint MSG_SYSTEM_WILL_NOT_SLEEP = 0xE0000290;
<* `kIOMessageSystemWillPowerOn`: the device tree is powering up. *>
const uint MSG_SYSTEM_WILL_POWER_ON  = 0xE0000320;
<* `kIOMessageSystemHasPoweredOn`: the system has woken. *>
const uint MSG_SYSTEM_HAS_POWERED_ON = 0xE0000300;
<* `kIOMessageSystemWillPowerOff`: shutdown is starting. *>
const uint MSG_SYSTEM_WILL_POWER_OFF = 0xE0000250;
<* `kIOMessageSystemWillRestart`: a restart is starting. *>
const uint MSG_SYSTEM_WILL_RESTART   = 0xE0000310;

<* A system power event, classified from the IOKit message. `OTHER` for messages not listed here. *>
enum PowerEvent : char
{
	CAN_SLEEP,
	WILL_SLEEP,
	WILL_NOT_SLEEP,
	WILL_POWER_ON,
	HAS_POWERED_ON,
	WILL_POWER_OFF,
	WILL_RESTART,
	OTHER,
}

<* Map an IOKit power message to a `PowerEvent`. *>
fn PowerEvent classify_message(uint message)
{
	switch (message)
	{
		case MSG_CAN_SYSTEM_SLEEP: return CAN_SLEEP;
		case MSG_SYSTEM_WILL_SLEEP: return WILL_SLEEP;
		case MSG_SYSTEM_WILL_NOT_SLEEP: return WILL_NOT_SLEEP;
		case MSG_SYSTEM_WILL_POWER_ON: return WILL_POWER_ON;
		case MSG_SYSTEM_HAS_POWERED_ON: return HAS_POWERED_ON;
		case MSG_SYSTEM_WILL_POWER_OFF: return WILL_POWER_OFF;
		case MSG_SYSTEM_WILL_RESTART: return WILL_RESTART;
		default: return OTHER;
	}
}
