<*
 External monitors on Windows: the high-level monitor API of dxva2.dll.

 `EnumDisplayMonitors` gives the display handles; `GetNumberOfPhysicalMonitorsFromHMONITOR`
 and `GetPhysicalMonitorsFromHMONITOR` give the physical monitors of each display;
 `GetMonitorBrightness` (minimum, current, maximum) and `SetMonitorBrightness` read
 and set the luminance (DDC/CI VCP 0x10 underneath). Each display's monitors are
 released with `DestroyPhysicalMonitors` using the count they were fetched with.

 COMPILED ONLY. Nothing here has run on Windows. Declarations as cited in
 docs/research/display.md section 2.3: MGW `highlevelmonitorconfigurationapi.h`
 lines 91 (GetMonitorBrightness) and 103 (SetMonitorBrightness),
 `physicalmonitorenumerationapi.h` lines 32-36. The handles and BOOL results are
 declared with C types; the layouts of PHYSICAL_MONITOR are the Windows SDK's.
*>
module bleu::brightness::windows_monitors @feat(WIN32) @link("dxva2");
import std::collections::list, std::collections::maybe, bleu::availability, bleu::brightness, bleu::error, bleu::unit;

<* `WCHAR szPhysicalMonitorDescription[128]`. *>
const usz DESCRIPTION_CHARS = 128;

<* A physical monitor as dxva2 reports it: its handle and a description (not used). *>
struct PhysicalMonitor
{
	void* handle;
	ushort[DESCRIPTION_CHARS] description;
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

// The monitors of one display, as fetched, so that they can be destroyed with the same count.
alias Chunk = PhysicalMonitor[];

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
		return error::raise(error::BACKEND_FAILURE, error::Domain.WIN32, 0, "EnumDisplayMonitors failed")~;
	}
	foreach (display : displays)
	{
		uint count = 0;
		if (!getNumberOfPhysicalMonitorsFromHMONITOR(display, &count) || count == 0) continue;
		Chunk chunk = alloc::new_array(tmem, PhysicalMonitor, (sz)count);
		// A display that refuses to list its monitors is skipped, not fatal.
		if (!getPhysicalMonitorsFromHMONITOR(display, count, chunk.ptr)) continue;
		chunks.push(chunk);
	}
}

// Destroy the monitors of every chunk.
fn void release_chunks(List{Chunk}* chunks)
{
	foreach (chunk : chunks)
	{
		(void)destroyPhysicalMonitors((uint)chunk.len, chunk.ptr);
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
		return error::raise(error::BACKEND_FAILURE, error::Domain.WIN32, 0, "SetMonitorBrightness refused %d", raw)~;
	}
	Maybe{Level} read_back = { };
	if (getMonitorBrightness(monitor.handle, &minimum, &current, &maximum))
	{
		read_back = maybe::value(unit::from_raw((long)current, (long)minimum, (long)maximum));
	}
	return brightness::applied_at(Mechanism.DDC, level, raw, (long)minimum, (long)maximum, read_back);
}