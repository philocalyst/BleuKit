<*
 The whole-system battery summary from `GetSystemPowerStatus`.

 It needs no device access, so it is the fallback when no battery device can be read
 (and the source of the AC line state in every case). The layout and the unknown
 markers are in `win32_convert.c3`.

 Sources: Microsoft Learn `ns-winbase-system_power_status` (SYSTEM_POWER_STATUS); the
 `windows-sys` 0.59.0 struct (`Win32::System::Power`, `kernel32` link) has the same five
 fields in the same order; psutil `_pswindows.py` reads the same flags (128, 8, AC line 1).
*>
module bleu::battery::win32 @feat(WIN32) @link("kernel32");
import std::collections::maybe, std::os::win32, bleu::battery, bleu::error, bleu::unit, bleu::win::errors;

<* SYSTEM_POWER_STATUS (winbase.h). 12 bytes: four bytes, then two DWORDs. *>
struct SystemPowerStatus
{
	char ac_line_status;
	char battery_flag;
	char battery_life_percent;
	char system_status_flag;
	uint battery_life_time;
	uint battery_full_life_time;
}

extern fn Win32_BOOL get_system_power_status(SystemPowerStatus* status) @cname("GetSystemPowerStatus");

<*
 Read the summary.

 @return? error::BACKEND_FAILURE : "when GetSystemPowerStatus fails"
*>
fn SystemPowerStatus? read_summary()
{
	SystemPowerStatus status;
	if (!get_system_power_status(&status)) return errors::raise_last("GetSystemPowerStatus")~;
	return status;
}

<*
 The summary as one `Source` with the id "system". Used only when no battery device
 answered and the summary says a battery exists.
*>
fn Source summary_source(Allocator allocator, SystemPowerStatus* status, bool on_mains)
{
	Maybe{Level} percent = summary_percent((uint)status.battery_life_percent);
	ChargeState state    = summary_state((uint)status.battery_flag, on_mains, percent);
	Source source        = {
		.id = "system".copy(allocator),
		.kind = BATTERY,
		.present = true,
		.state = state,
		.charge = percent
	};
	if (state == DISCHARGING) source.time_to_empty = summary_seconds(status.battery_life_time);
	return source;
}