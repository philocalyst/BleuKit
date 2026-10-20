<*
 Win32 declarations for the Windows mechanism: GetSystemPowerStatus,
 PowerCreateRequest, PowerSetRequest, PowerClearRequest and CloseHandle
 (kernel32). Signatures, layouts and constants come from windows-sys 0.59.0
 (`System/Power/mod.rs`, `System/Threading/mod.rs`, `System/SystemServices/mod.rs`,
 `Foundation/mod.rs`), cross-checked against Microsoft Learn for
 PowerCreateRequest (returns INVALID_HANDLE_VALUE on failure). See
 docs/research/battery_power.md, rows V46 to V51.
*>
module bleu::power::windows_api @feat(WIN32);
import std::os::win32;

<* `SYSTEM_POWER_STATUS` (winbase.h): the layout is four bytes, then two DWORDs. *>
struct SystemPowerStatus
{
	char ac_line_status; // 0 offline, 1 online, 255 unknown
	char battery_flag;
	char battery_life_percent;
	char system_status_flag; // 1 when battery saver is on, 0 when it is off
	uint battery_life_time;
	uint battery_full_life_time;
}

<* `REASON_CONTEXT` for PowerCreateRequest: Version, Flags, then the union whose simple form is a PWSTR. *>
struct ReasonContext
{
	uint version;
	uint flags;
	Char16* simple_reason;
}

<* `POWER_REQUEST_CONTEXT_VERSION` (SystemServices): the only defined version. *>
const uint POWER_REQUEST_CONTEXT_VERSION       = 0;
<* `POWER_REQUEST_CONTEXT_SIMPLE_STRING` (Threading): the reason is a plain string. *>
const uint POWER_REQUEST_CONTEXT_SIMPLE_STRING = 1;
<* `PowerRequestDisplayRequired` (POWER_REQUEST_TYPE). *>
const int POWER_REQUEST_DISPLAY_REQUIRED       = 0;
<* `PowerRequestSystemRequired` (POWER_REQUEST_TYPE). *>
const int POWER_REQUEST_SYSTEM_REQUIRED        = 1;
<* `INVALID_HANDLE_VALUE`, what PowerCreateRequest returns on failure. *>
const usz INVALID_HANDLE                       = ~(usz)0;

extern fn Win32_BOOL getSystemPowerStatus(SystemPowerStatus* status) @cname("GetSystemPowerStatus");
extern fn void* powerCreateRequest(ReasonContext* context) @cname("PowerCreateRequest");
extern fn Win32_BOOL powerSetRequest(void* request, int type) @cname("PowerSetRequest");
extern fn Win32_BOOL powerClearRequest(void* request, int type) @cname("PowerClearRequest");
extern fn Win32_BOOL closeHandle(void* handle) @cname("CloseHandle");