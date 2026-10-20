<*
 External monitors on Windows: the high-level monitor API of dxva2.dll.

 `EnumDisplayMonitors` gives the display handles; `GetNumberOfPhysicalMonitorsFromHMONITOR`
 and `GetPhysicalMonitorsFromHMONITOR` give the physical monitors of each display;
 `GetMonitorBrightness` (minimum, current, maximum) and `SetMonitorBrightness` read
 and set the luminance (DDC/CI VCP 0x10 underneath). Each display's monitors are
 released with `DestroyPhysicalMonitors` using the count they were fetched with.
 A monitor's id is its display's device name and its position within that display
 (`monitor_id`), so it does not change when another monitor appears or goes.

 COMPILED ONLY. Nothing here has run on Windows. Declarations as cited in
 docs/research/display.md section 2.3: MGW `highlevelmonitorconfigurationapi.h`
 lines 91 (GetMonitorBrightness) and 103 (SetMonitorBrightness),
 `physicalmonitorenumerationapi.h` lines 32-36. The handles and BOOL results are
 declared with C types; the layouts of PHYSICAL_MONITOR are the Windows SDK's.
*>
module bleu::brightness::windows_monitors @feat(WIN32) @link("dxva2");
import std::collections::list, std::collections::maybe, std::os::win32, bleu::availability, bleu::brightness, bleu::error, bleu::unit;

<* `WCHAR szPhysicalMonitorDescription[128]`. *>
const usz DESCRIPTION_CHARS = 128;

<* A physical monitor as dxva2 reports it: its handle and a description (not used). *>
struct PhysicalMonitor
{
	void* handle;
	ushort[DESCRIPTION_CHARS] description;
}

// `WCHAR szDevice[CCHDEVICENAME]` in MONITORINFOEXW.
const usz DEVICE_NAME_CHARS = 32;

// `MONITORINFOEXW` (winuser.h): its size is 104 bytes on every Windows target, and that is the `cbSize` it must carry.
const uint MONITOR_INFO_EX_SIZE = 104;

<* `MONITORINFOEXW`: the display's rectangles, flags and device name (the DISPLAY1 style of name). *>
struct MonitorInfoExW
{
	uint size;
	int[4] monitor;
	int[4] work;
	uint flags;
	ushort[DEVICE_NAME_CHARS] device;
}

// `BOOL CALLBACK MonitorEnumProc(HMONITOR, HDC, LPRECT, LPARAM)`.
alias MonitorEnumFn = fn int(void* display, void* context, void* rect, long data);

extern fn int enumDisplayMonitors(
	void* context,
	void* clip,
	MonitorEnumFn callback,
	long data
) @cname("EnumDisplayMonitors");
extern fn int getNumberOfPhysicalMonitorsFromHMONITOR(
	void* display,
	uint* count
) @cname("GetNumberOfPhysicalMonitorsFromHMONITOR");
extern fn int getPhysicalMonitorsFromHMONITOR(
	void* display,
	uint count,
	PhysicalMonitor* out
) @cname("GetPhysicalMonitorsFromHMONITOR");
extern fn int destroyPhysicalMonitors(uint count, PhysicalMonitor* monitors) @cname("DestroyPhysicalMonitors");
extern fn int getMonitorBrightness(
	void* handle,
	uint* minimum,
	uint* current,
	uint* maximum
) @cname("GetMonitorBrightness");
extern fn int setMonitorBrightness(void* handle, uint value) @cname("SetMonitorBrightness");
extern fn int getMonitorInfoW(void* display, MonitorInfoExW* info) @cname("GetMonitorInfoW");

<*
 The physical monitors of one display, with the display's device name. The monitors are
 destroyed with the count they were fetched with.
*>
struct Chunk
{
	String display;
	PhysicalMonitor[] monitors;
}

<*
 The id of the `index`th monitor of display `display` (its device name): stable while the
 display stays attached, and it names the monitor a write must reach.
*>
fn String monitor_id(String display, sz index) => string::tformat("%s#%d", display, index);

// Collect every display handle into the list that `data` points to.
fn int collect_display(void* display, void* context, void* rect, long data)
{
	List{void*}* displays = (List{void*}*)(usz)data;
	displays.push(display);
	return 1;
}

<*
 The physical monitors of every display, one chunk per display, in temporary
 memory. Release the chunks with `release_chunks`.

 @return? error::BACKEND_FAILURE : "EnumDisplayMonitors failed"
*>
fn void? enumerate(List{Chunk}* chunks)
{
	List{void*} displays;
	displays.init(tmem);
	if (!enumDisplayMonitors(null, null, &collect_display, (long)(usz)&displays))
	{
		return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.WIN32,
			(int)win32::getLastError(),
			"EnumDisplayMonitors failed"
		)~;
	}
	foreach (display : displays)
	{
		MonitorInfoExW info;
		info.size = MONITOR_INFO_EX_SIZE;
		// A display without a device name cannot be told apart from another, so it is skipped.
		if (!getMonitorInfoW(display, &info)) continue;
		uint count = 0;
		if (!getNumberOfPhysicalMonitorsFromHMONITOR(display, &count) || count == 0) continue;
		PhysicalMonitor[] monitors = alloc::new_array(tmem, PhysicalMonitor, (sz)count);
		// A display that refuses to list its monitors is skipped, not fatal.
		if (!getPhysicalMonitorsFromHMONITOR(display, count, monitors.ptr)) continue;
		chunks.push({ .display = device_name(&info), .monitors = monitors });
	}
}

// The display's device name, copied into temporary memory. Windows names displays in ASCII; any other character is written as '?'.
fn String device_name(MonitorInfoExW* info) @private
{
	char[DEVICE_NAME_CHARS] buffer;
	usz length = 0;
	while (length < DEVICE_NAME_CHARS && info.device[length] != 0)
	{
		ushort code = info.device[length];
		buffer[length] = code < 128 ? (char)code : '?';
		length++;
	}
	return ((String)buffer[0:length]).copy(tmem);
}

// Destroy the monitors of every chunk.
fn void release_chunks(List{Chunk}* chunks)
{
	foreach (chunk : chunks)
	{
		(void)destroyPhysicalMonitors((uint)chunk.monitors.len, chunk.monitors.ptr);
	}
}

<*
 The luminance control of one physical monitor. Unreadable monitors say why.
*>
fn Control monitor_control(PhysicalMonitor* monitor)
{
	uint minimum = 0;
	uint current = 0;
	uint maximum = 0;
	if (!getMonitorBrightness(monitor.handle, &minimum, &current, &maximum) || maximum <= minimum)
	{
		return {
			.mechanism = DDC,
			.availability = availability::no(
				HARDWARE_ABSENT,
				"the monitor did not answer the high-level brightness call"
			)
		};
	}
	return {
		.mechanism = DDC,
		.readable = true,
		.writable = true,
		.availability = availability::YES,
		.level = maybe::value(unit::from_raw((long)current, (long)minimum, (long)maximum)),
		.raw = maybe::value((long)current),
		.raw_min = (long)minimum,
		.raw_max = (long)maximum,
	};
}

<*
 Set one physical monitor to `level` and read it back.

 @return? error::UNAVAILABLE : "The monitor does not report a luminance range"
 @return? error::BACKEND_FAILURE : "The monitor refused the set"
*>
fn Applied? write_monitor(PhysicalMonitor* monitor, Level level)
{
	uint minimum = 0;
	uint current = 0;
	uint maximum = 0;
	if (!getMonitorBrightness(monitor.handle, &minimum, &current, &maximum) || maximum <= minimum)
	{
		return error::raise(error::UNAVAILABLE, error::Domain.WIN32, 0, "the monitor reports no luminance range")~;
	}
	long raw = level.to_raw((long)minimum, (long)maximum);
	if (!setMonitorBrightness(monitor.handle, (uint)raw))
	{
		return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.WIN32,
			(int)win32::getLastError(),
			"SetMonitorBrightness refused %d",
			raw
		)~;
	}
	Maybe{Level} read_back = { };
	if (getMonitorBrightness(monitor.handle, &minimum, &current, &maximum))
	{
		read_back = maybe::value(unit::from_raw((long)current, (long)minimum, (long)maximum));
	}
	brightness::confirm_read_back("external monitor", raw, (long)minimum, (long)maximum, read_back)!;
	return brightness::applied_at(Mechanism.DDC, level, raw, (long)minimum, (long)maximum, read_back);
}