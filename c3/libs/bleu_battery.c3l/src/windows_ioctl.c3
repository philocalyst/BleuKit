<*
 Reading one battery device with the battery class IOCTLs.

 Per poll, for each interface from `windows_setup.c3`: open the device, ask for its
 tag, then its static information (BATTERY_INFORMATION) and its dynamic status
 (BATTERY_STATUS). Those are the three queries of starship-battery 0.10.0
 `src/platform/windows/ffi/mod.rs`. Other information levels (temperature, device
 name, manufacturer, serial) are not read in v1: see the lib README.

 Sources (every layout and value is checked against two sources):
 - IOCTL codes and the BATTERY_* structures: `windows-sys` 0.59.0
 `Win32::System::Power` (batclass.h constants and struct definitions) and Microsoft
 Learn `battery-information-str`, `battery-status-str`, `battery-wait-status-str`.
 - CTL_CODE decoding: device 0x29, function 0x10/0x11/0x13, METHOD_BUFFERED, FILE_READ_ACCESS
 for the three queries (bits 14-15 of 0x294040 are 1). The reads need no write access, so the
 device is opened with GENERIC_READ only.
 - CreateFileW, DeviceIoControl: `windows-sys` `Win32::Storage::FileSystem` and `System::IO`.
*>
module bleu::battery::win32 @feat(WIN32) @link("kernel32");
import std::collections::maybe, std::os::win32, bleu::battery, bleu::error, bleu::unit, bleu::win::errors, bleu::win::text;

// CreateFileW flags (winnt.h; windows-sys: GENERIC_READ 0x80000000, FILE_SHARE_* 1 and 2, OPEN_EXISTING 3).
const uint IO_GENERIC_READ     = 0x80000000;
const uint IO_FILE_SHARE_READ  = 0x00000001;
const uint IO_FILE_SHARE_WRITE = 0x00000002;
const uint IO_OPEN_EXISTING    = 3;

// Battery class IOCTLs (batclass.h; windows-sys: 2703424, 2703428, 2703436).
const uint IOCTL_BATTERY_QUERY_TAG         = 0x00294040;
const uint IOCTL_BATTERY_QUERY_INFORMATION = 0x00294044;
const uint IOCTL_BATTERY_QUERY_STATUS      = 0x0029404C;

// Information level for BATTERY_QUERY_INFORMATION (windows-sys: BatteryInformation = 0).
const uint BATTERY_INFORMATION_LEVEL = 0;
// A tag of zero means the device is not a valid battery (windows-sys: BATTERY_TAG_INVALID = 0).
const uint BATTERY_TAG_INVALID       = 0;

extern fn Win32_HANDLE create_file_w(
	WString name,
	uint access,
	uint share,
	void* security,
	uint disposition,
	uint flags,
	Win32_HANDLE template
) @cname("CreateFileW");
extern fn Win32_BOOL device_io_control(
	Win32_HANDLE device,
	uint code,
	void* input,
	uint input_size,
	void* output,
	uint output_size,
	uint* returned,
	void* overlapped
) @cname("DeviceIoControl");

<*
 BATTERY_INFORMATION (batclass.h; Learn battery-information-str). 36 bytes.
 `capabilities` carries BATTERY_CAPACITY_RELATIVE, the units flag.
*>
struct BatteryInformation
{
	uint capabilities;
	char technology;
	char[3] reserved;
	char[4] chemistry;
	uint designed_capacity;
	uint full_charged_capacity;
	uint default_alert1;
	uint default_alert2;
	uint critical_bias;
	uint cycle_count;
}

<* BATTERY_STATUS (batclass.h; Learn battery-status-str). 16 bytes. `rate` is signed. *>
struct BatteryStatus
{
	uint power_state;
	uint capacity;
	uint voltage;
	int rate;
}

<* BATTERY_QUERY_INFORMATION (batclass.h): the tag and the level asked for. *>
struct BatteryQueryInformation
{
	uint battery_tag;
	uint information_level;
	uint at_rate;
}

<* BATTERY_WAIT_STATUS (batclass.h; Learn battery-wait-status-str). Timeout 0 returns at once. *>
struct BatteryWaitStatus
{
	uint battery_tag;
	uint timeout;
	uint power_state;
	uint low_capacity;
	uint high_capacity;
}

<* Open a battery device path for reading. The caller closes the handle. *>
fn Win32_HANDLE? open_device(String path)
{
	WideZ wide = text::to_wide(tmem, path)!;
	Win32_HANDLE handle = create_file_w(
		wide.as_wstring(),
		IO_GENERIC_READ,
		IO_FILE_SHARE_READ | IO_FILE_SHARE_WRITE,
		null,
		IO_OPEN_EXISTING,
		0,
		null
	);
	if (handle == win32::INVALID_HANDLE_VALUE) return errors::raise_last("CreateFileW")~;
	return handle;
}

<* One IOCTL: `input` in, `output` out, both of the given sizes. A short reply is an error. *>
fn void? control(Win32_HANDLE device, uint code, void* input, uint input_size, void* output, uint output_size)
{
	uint returned = 0;
	if (!device_io_control(device, code, input, input_size, output, output_size, &returned, null))
	{
		return errors::raise_last("DeviceIoControl")~;
	}
	if (returned < output_size) return error::raise(
		error::BACKEND_FAILURE,
		error::Domain.WIN32,
		0,
		"battery IOCTL %d returned %d of %d bytes",
		(int)code,
		(int)returned,
		(int)output_size
	)~;
}

<* The battery tag of a device. `UNAVAILABLE` for a device that is not a battery yet. *>
fn uint? query_tag(Win32_HANDLE device)
{
	uint timeout = 0;
	uint tag     = 0;
	control(device, IOCTL_BATTERY_QUERY_TAG, &timeout, uint::size, &tag, uint::size)!;
	if (tag == BATTERY_TAG_INVALID) return error::UNAVAILABLE~;
	return tag;
}

<* The static description of the battery with `tag`. *>
fn BatteryInformation? query_information(Win32_HANDLE device, uint tag)
{
	BatteryQueryInformation query = {
		.battery_tag = tag,
		.information_level = BATTERY_INFORMATION_LEVEL,
		.at_rate = 0
	};
	BatteryInformation info;
	control(
		device,
		IOCTL_BATTERY_QUERY_INFORMATION,
		&query,
		BatteryQueryInformation::size,
		&info,
		BatteryInformation::size
	)!;
	return info;
}

<* The current status of the battery with `tag`, read without waiting. *>
fn BatteryStatus? query_status(Win32_HANDLE device, uint tag)
{
	BatteryWaitStatus wait = {
		.battery_tag = tag,
		.timeout = 0,
		.power_state = 0,
		.low_capacity = 0,
		.high_capacity = 0
	};
	BatteryStatus status;
	control(device, IOCTL_BATTERY_QUERY_STATUS, &wait, BatteryWaitStatus::size, &status, BatteryStatus::size)!;
	return status;
}

<*
 Read one battery device into a `Source`, with `path` as its id.

 @return? NOT_FOUND : "for a battery with relative units, which v1 does not convert"
 @return? error::UNAVAILABLE : "when the device is not a battery"
*>
fn Source? read_device(Allocator allocator, String path)
{
	Win32_HANDLE device = open_device(path)!;
	defer win32::closeHandle(device);
	uint tag                = query_tag(device)!;
	BatteryInformation info = query_information(device, tag)!;
	BatteryStatus status    = query_status(device, tag)!;
	if (device_is_relative(info.capabilities)) return NOT_FOUND~;
	return device_source(allocator, path, &info, &status);
}

<* Map the two IOCTL answers onto a `Source`. Capacities are mWh, rate is mW (positive charging). *>
fn Source device_source(Allocator allocator, String path, BatteryInformation* info, BatteryStatus* status)
{
	Maybe{MilliWattHour} energy = device_capacity(status.capacity);
	Maybe{MilliWattHour} full   = device_capacity(info.full_charged_capacity);
	Maybe{MilliWattHour} design = device_capacity(info.designed_capacity);
	bool has_both               = energy.has_value && full.has_value;
	bool is_full                = has_both && energy.value >= full.value;
	bool is_empty               = energy.has_value && energy.value == (MilliWattHour)0;
	Source source = {
		.id = path.copy(allocator),
		.kind = BATTERY,
		.present = true,
		.state = device_state(status.power_state, is_full, is_empty),
		.energy = energy,
		.energy_full = full,
		.energy_design = design,
		.cycles = device_cycles(info.cycle_count),
	};
	if (has_both && full.value > (MilliWattHour)0)
	{
		source.charge = maybe::value(unit::from_ratio((double)energy.value, (double)full.value));
	}
	if (full.has_value && design.has_value)
	{
		source.health = battery::health_from(full.value, design.value);
	}
	Maybe{MilliWatt} rate = device_rate(status.rate);
	if (rate.has_value && (source.state == CHARGING || source.state == DISCHARGING))
	{
		source.power = rate;
		if (source.state == DISCHARGING && energy.has_value)
		{
			source.time_to_empty = battery::time_at_rate(energy.value, rate.value);
		}
		if (source.state == CHARGING && has_both && energy.value < full.value)
		{
			source.time_to_full = battery::time_at_rate(full.value - energy.value, rate.value);
		}
	}
	return source;
}