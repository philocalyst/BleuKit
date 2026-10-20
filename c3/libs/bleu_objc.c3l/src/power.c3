<*
 Power for macOS services: the battery and AC state (IOPowerSources), sleep
 inhibition (IOPMAssertion) and system sleep/wake notifications (IORegisterForSystemPower).

 Sources (signatures and constants):
 * `IOPowerSources.h` and `IOPSKeys.h` in apple-oss-distributions/IOKitUser (`ps.subproj/`):
 IOPSCopyPowerSourcesInfo, IOPSCopyPowerSourcesList, IOPSGetPowerSourceDescription,
 IOPSNotificationCreateRunLoopSource, IOPSCopyExternalPowerAdapterDetails, and the
 key strings ("Power Source State", "Current Capacity", "Time to Empty" in minutes, -1 = calculating).
 * `IOPMLib.h` (`pwr_mgt.subproj/`): IOPMAssertionCreateWithName, IOPMAssertionRelease,
 kIOPMAssertPreventUserIdleSystemSleep, kIOPMAssertionLevelOn = 255, IORegisterForSystemPower,
 IODeregisterForSystemPower, IOAllowPowerChange.
 * `IOMessage.h` (xnu `iokit/IOKit/IOMessage.h`): the `iokit_common_msg` codes.
 * Second source for all of the above: io-kit-sys 0.4.1 `src/`, and the `core-foundation-sys`
 and `io-kit-sys` crates' key and message constants.
*>
module bleu::iokit::power @feat(DARWIN) @link("IOKit.framework");
import bleu::error, bleu::unit, bleu::iokit, bleu::cf, bleu::mach, bleu::objc;

<* `kCFRunLoopDefaultMode`: the mode a power source is attached in. *>
extern const void* KCF_RUNLOOP_DEFAULT_MODE @cname("kCFRunLoopDefaultMode");

extern fn CFTypeRef io_ps_copy_power_sources_info() @cname("IOPSCopyPowerSourcesInfo");
extern fn CFTypeRef io_ps_copy_power_sources_list(CFTypeRef blob) @cname("IOPSCopyPowerSourcesList");
extern fn CFTypeRef io_ps_get_power_source_description(
	CFTypeRef blob,
	CFTypeRef source
) @cname("IOPSGetPowerSourceDescription");
extern fn void* io_ps_notification_create_run_loop_source(
	void* callback,
	void* context
) @cname("IOPSNotificationCreateRunLoopSource");
extern fn CFTypeRef io_ps_copy_external_power_adapter_details() @cname("IOPSCopyExternalPowerAdapterDetails");
extern fn CFTypeRef cf_dictionary_get_value(CFTypeRef dictionary, CFTypeRef key) @cname("CFDictionaryGetValue");
extern fn void cf_run_loop_add_source(void* loop, void* source, void* mode) @cname("CFRunLoopAddSource");

extern fn int io_pm_assertion_create_with_name(
	CFTypeRef type,
	uint level,
	CFTypeRef name,
	uint* id
) @cname("IOPMAssertionCreateWithName");
extern fn int io_pm_assertion_release(uint id) @cname("IOPMAssertionRelease");
extern fn uint io_register_for_system_power(
	void* refcon,
	void** port,
	IoInterest callback,
	iokit::IoObject* notifier
) @cname("IORegisterForSystemPower");
extern fn int io_deregister_for_system_power(iokit::IoObject* notifier) @cname("IODeregisterForSystemPower");
extern fn int io_allow_power_change(uint kernel_port, long notification_id) @cname("IOAllowPowerChange");

<* The `IOServiceInterestCallback` shape used by `IORegisterForSystemPower`. *>
alias IoInterest = fn void(void* refcon, iokit::IoObject service, uint message, void* argument);

<* `IOPSPowerSourceState` value for a battery that is not on external power (IOPSKeys.h `kIOPSBatteryPowerValue`). *>
const ZString PS_BATTERY_POWER = "Battery Power";
<* `kIOPSACPowerValue`: on external power. *>
const ZString PS_AC_POWER      = "AC Power";
<* `kIOPSOffLineValue`: the source is off-line. *>
const ZString PS_OFF_LINE      = "Off Line";

<* Key names of a power-source description dictionary (IOPSKeys.h). *>
const ZString PS_KEY_NAME     = "Name";
<* `kIOPSTypeKey`: the source type (`InternalBattery` or a UPS). *>
const ZString PS_KEY_TYPE     = "Type";
<* `kIOPSPowerSourceStateKey`. *>
const ZString PS_KEY_STATE    = "Power Source State";
<* `kIOPSIsPresentKey`. *>
const ZString PS_KEY_PRESENT  = "Is Present";
<* `kIOPSIsChargingKey`. *>
const ZString PS_KEY_CHARGING = "Is Charging";
<* `kIOPSCurrentCapacityKey`. *>
const ZString PS_KEY_CURRENT  = "Current Capacity";
<* `kIOPSMaxCapacityKey`. *>
const ZString PS_KEY_MAXIMUM  = "Max Capacity";
<* `kIOPSTimeToEmptyKey`: minutes on battery. *>
const ZString PS_KEY_TO_EMPTY = "Time to Empty";
<* `kIOPSTimeToFullChargeKey`: minutes to full while charging. *>
const ZString PS_KEY_TO_FULL  = "Time to Full Charge";

<* `kIOPMAssertPreventUserIdleSystemSleep` (IOPMLib.h): keep the system awake while the user is idle. *>
const ZString ASSERTION_PREVENT_USER_IDLE_SYSTEM_SLEEP = "PreventUserIdleSystemSleep";
<* `kIOPMAssertionLevelOn` (IOPMLib.h): the assertion is in force. *>
const uint ASSERTION_LEVEL_ON                          = 255;

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

<* Power-source state, from `kIOPSPowerSourceStateKey`. *>
enum PowerSourceState : char
{
	UNKNOWN, // the key is absent or has an unexpected value
	AC,      // on external power
	BATTERY, // drawing from the battery
	OFFLINE, // the source is off-line
}

<*
 One power source (the internal battery, or a UPS), as published by IOPowerSources.
 Fields the system did not publish hold their zero value: `name` and `type` are ""
 and `minutes_*` are -1 when the system is still calculating or has no estimate.
*>
struct PowerSource
{
	String name;
	String type;
	PowerSourceState state;
	bool present;
	bool charging;
	unit::Level charge;
	int minutes_to_empty;
	int minutes_to_full;
}

<* Minutes value meaning "no estimate" (IOPSKeys.h: -1 = still calculating). *>
const int MINUTES_UNKNOWN = -1;

<*
 Read a value from a power-source description, borrowed from it. Null when absent.
*>
fn CFTypeRef description_value(CFTypeRef description, ZString key)
{
	cf::Ref name = cf::from_string(key.str_view());
	defer name.close();
	return cf_dictionary_get_value(description, name.ptr);
}

<* A boolean key, false when absent. *>
fn bool description_bool(CFTypeRef description, ZString key)
{
	CFTypeRef value = description_value(description, key);
	return value && cf::type_of(value) == cf::boolean_type_id() ? cf_boolean_value(value) : false;
}

<* An integer key, `MINUTES_UNKNOWN` when absent. *>
fn int description_minutes(CFTypeRef description, ZString key)
{
	CFTypeRef value = description_value(description, key);
	if (!value || cf::type_of(value) != cf::number_type_id()) return MINUTES_UNKNOWN;
	return (int)(cf::number_long(value) ?? MINUTES_UNKNOWN);
}

<* A number key as a double, 0 when absent. *>
fn double description_real(CFTypeRef description, ZString key)
{
	CFTypeRef value = description_value(description, key);
	if (!value || cf::type_of(value) != cf::number_type_id()) return 0;
	return cf::number_double(value);
}

<* A string key, copied into `allocator`; "" when absent or not a string. *>
fn String description_text(CFTypeRef description, ZString key, Allocator allocator)
{
	CFTypeRef value = description_value(description, key);
	if (!value || cf::type_of(value) != cf::string_type_id()) return "";
	return cf::string_value(value, allocator) ?? "";
}

<* Boolean value of a CFBoolean (`CFBooleanGetValue`). *>
extern fn bool cf_boolean_value(CFTypeRef boolean) @cname("CFBooleanGetValue");

<*
 Read the current power sources, one `PowerSource` per source, allocated from `allocator`.

 @return? error::BACKEND_FAILURE : "when IOPowerSources cannot produce a snapshot"
*>
fn PowerSource[]? read_power_sources(Allocator allocator)
{
	cf::Ref snapshot = cf::adopt(io_ps_copy_power_sources_info());
	defer snapshot.close();
	if (snapshot.is_nil()) return error::raise(
		error::BACKEND_FAILURE,
		error::Domain.MACH,
		0,
		"IOPSCopyPowerSourcesInfo returned nothing"
	)~;
	cf::Ref sources = cf::adopt(io_ps_copy_power_sources_list(snapshot.ptr));
	defer sources.close();
	sz count             = cf::array_count(sources.ptr);
	PowerSource[] result = alloc::new_array(allocator, PowerSource, count);
	for (sz i = 0; i < count; i++)
	{
		CFTypeRef source      = cf::array_at(sources.ptr, i);
		CFTypeRef description = io_ps_get_power_source_description(snapshot.ptr, source);
		if (!description) return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.MACH,
			0,
			"no description for power source %d",
			(int)i
		)~;
		result[i] = describe(description, allocator);
	}
	return result;
}

<* Convert one description dictionary into a `PowerSource`. *>
fn PowerSource describe(CFTypeRef description, Allocator allocator) @local
{
	String state_text      = description_text(description, PS_KEY_STATE, tmem);
	PowerSourceState state = UNKNOWN;
	if (state_text == PS_AC_POWER) state = AC;
	if (state_text == PS_BATTERY_POWER) state = BATTERY;
	if (state_text == PS_OFF_LINE) state = OFFLINE;
	double current = description_real(description, PS_KEY_CURRENT);
	double maximum = description_real(description, PS_KEY_MAXIMUM);
	return {
		.name = description_text(description, PS_KEY_NAME, allocator),
		.type = description_text(description, PS_KEY_TYPE, allocator),
		.state = state,
		.present = description_bool(description, PS_KEY_PRESENT),
		.charging = description_bool(description, PS_KEY_CHARGING),
		.charge = unit::from_ratio(current, maximum),
		.minutes_to_empty = description_minutes(description, PS_KEY_TO_EMPTY),
		.minutes_to_full = description_minutes(description, PS_KEY_TO_FULL),
	};
}

<*
 Details of the connected power adapter (wattage, family, voltage), as an owned
 CoreFoundation dictionary. Convert with `cf::property_to_plain` if needed.

 @return? NOT_FOUND : "when no external adapter is connected"
*>
fn cf::Ref? external_adapter_details()
{
	cf::Ref details = cf::adopt(io_ps_copy_external_power_adapter_details());
	if (details.is_nil()) return NOT_FOUND~;
	return details;
}

<*
 A run-loop source that calls `callback(context)` whenever the power sources
 change (plugged in, unplugged, battery level). Owned; attach it to a loop with
 `attach_source`, then close it.

 @return? error::BACKEND_FAILURE : "when IOPowerSources cannot create the source"
*>
fn cf::Ref? power_source_change_source(IoPowerSourceChanged callback, void* context)
{
	void* source = io_ps_notification_create_run_loop_source((void*)callback, context);
	if (!source) return error::raise(
		error::BACKEND_FAILURE,
		error::Domain.MACH,
		0,
		"IOPSNotificationCreateRunLoopSource failed"
	)~;
	return cf::adopt(source);
}

<* Called when the power sources change. Runs on the loop that the source is attached to. *>
alias IoPowerSourceChanged = fn void(void* context);

<* Attach a run-loop source (from this module or `NotificationPort.source()`) to `loop` in the default mode. *>
fn void attach_source(void* loop, void* source) => cf_run_loop_add_source(loop, source, KCF_RUNLOOP_DEFAULT_MODE);

<*
 An IOPMAssertion that keeps the system from idle sleep. Held until `release`.
 Dropping it without `release` leaks the assertion until the process exits.
*>
struct SleepAssertion
{
	uint id;
	bool held;
}

<*
 Ask the system to stay awake while the user is idle. `reason` appears in
 `pmset -g assertions`.

 @return? error::BACKEND_FAILURE : "when IOPMAssertionCreateWithName refuses the assertion"
*>
fn SleepAssertion? prevent_idle_sleep(ZString reason)
{
	cf::Ref type = cf::from_string(ASSERTION_PREVENT_USER_IDLE_SYSTEM_SLEEP.str_view());
	defer type.close();
	cf::Ref name = cf::from_string(reason.str_view());
	defer name.close();
	uint id    = 0;
	int result = io_pm_assertion_create_with_name(type.ptr, ASSERTION_LEVEL_ON, name.ptr, &id);
	if (result != 0) return mach::raise_code(result, "IOPMAssertionCreateWithName")~;
	return { .id = id, .held = true };
}

<* Release the assertion. Idempotent. *>
fn void SleepAssertion.release(&self)
{
	if (self.held) io_pm_assertion_release(self.id);
	self.held = false;
}

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

<* Called on the power notification's run loop for each event. *>
alias PowerEventHandler = fn void(void* context, PowerEvent event);

<*
 System sleep, wake, and shutdown notifications (`IORegisterForSystemPower`).

 Sleep is never vetoed: the module acknowledges `CAN_SLEEP` and `WILL_SLEEP`
 with `IOAllowPowerChange` after the handler returns, because a sleep that is
 not acknowledged proceeds after a 30-second timeout anyway (IOPMLib.h).
*>
struct SystemPower
{
	uint root;
	iokit::IoObject notifier;
	iokit::NotificationPort port;
	PowerEventHandler handler;
	void* context;
}

<*
 Register for system power events. The registration is heap-allocated because
 IOKit keeps its address as the callback context, so it must not move. Attach
 `port` to a run loop with `attach_source(loop, power.port.source())`. Close the
 registration after that loop has stopped; `close` frees it.

 @return? error::BACKEND_FAILURE : "when the Root Power Domain refuses the registration"
*>
fn SystemPower*? register_system_power(PowerEventHandler handler, void* context)
{
	SystemPower* power = alloc::new(mem, SystemPower);
	power.handler = handler;
	power.context = context;
	void* port_ref = null;
	power.root = io_register_for_system_power(power, &port_ref, &system_power_callback, &power.notifier);
	if (!power.root)
	{
		alloc::free(mem, power);
		return error::raise(error::BACKEND_FAILURE, error::Domain.MACH, 0, "IORegisterForSystemPower failed")~;
	}
	power.port = { .port = port_ref };
	return power;
}

<*
 Deregister, close the root connection and destroy the port, then free the
 registration. Call only after the port's loop has stopped. The pointer must not
 be used afterwards.
*>
fn void SystemPower.close(&self)
{
	if (self.notifier) io_deregister_for_system_power(&self.notifier);
	if (self.root) iokit::io_service_close(self.root);
	self.port.close();
	alloc::free(mem, self);
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

<* The IOKit callback: classify, deliver, acknowledge sleep. Runs on the power port's run loop. *>
fn void system_power_callback(void* refcon, iokit::IoObject service, uint message, void* argument) @local
{
	SystemPower* power = (SystemPower*)refcon;
	PowerEvent event   = classify_message(message);
	objc::@objc_entry()
	{
		if (power.handler) power.handler(power.context, event);
	};
	if (event == CAN_SLEEP || event == WILL_SLEEP) io_allow_power_change(power.root, (long)argument);
}