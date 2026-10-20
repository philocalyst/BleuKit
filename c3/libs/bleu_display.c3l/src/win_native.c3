<*
 The display-configuration API of Windows, bound directly: QueryDisplayConfig, SetDisplayConfig and
 their structures, DisplayConfigGetDeviceInfo, and EnumDisplaySettingsExW (the mode list of a display).
 Layouts and constants are taken from the mingw-w64 wingdi.h and winuser.h headers (MGW), which
 match the Windows SDK, and cross-checked against the Microsoft Learn pages cited in
 docs/research/display.md. The standard library binds none of these functions.

 Bit layouts: the source and target indices of a path are the two 16-bit halves of its `modeInfoIdx`
 (wingdi.h, DISPLAYCONFIG_PATH_SOURCE_INFO and DISPLAYCONFIG_PATH_TARGET_INFO). The low half is the
 first bit-field, so a source mode index is the high half: (value >> 16) & 0xFFFF.
*>
module bleu::display::win_native @feat(WIN32) @link("user32");
import std::os::win32;

// QueryDisplayConfig flags (wingdi.h).
const uint QDC_ALL_PATHS = 0x1;

// DISPLAYCONFIG_PATH_INFO flags (wingdi.h).
const uint DISPLAYCONFIG_PATH_ACTIVE = 0x1;

// Index halves of a path's mode-info field, and the value that marks "no index".
const uint MODE_INDEX_INVALID = 0xFFFF;

// Device info types, DISPLAYCONFIG_DEVICE_INFO_TYPE (wingdi.h).
const uint DEVICE_INFO_SOURCE_NAME = 1;
const uint DEVICE_INFO_TARGET_NAME = 2;

// DISPLAYCONFIG_MODE_INFO_TYPE (wingdi.h).
const uint MODE_INFO_SOURCE = 1;
const uint MODE_INFO_TARGET = 2;

// SetDisplayConfig flags (wingdi.h).
const uint SDC_APPLY                       = 0x80;
const uint SDC_VALIDATE                    = 0x40;
const uint SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x20;
const uint SDC_SAVE_TO_DATABASE            = 0x200;
const uint SDC_ALLOW_CHANGES               = 0x400;

// The size of a CCHDEVICENAME buffer (wingdi.h).
const usz CCH_DEVICE_NAME = 32;

// LUID: the adapter a path or device belongs to.
struct Luid
{
	uint low_part;
	int high_part;
}

// DISPLAYCONFIG_RATIONAL: a frequency as numerator over denominator.
struct Rational
{
	uint numerator;
	uint denominator;
}

// DISPLAYCONFIG_2DREGION.
struct Region
{
	uint cx;
	uint cy;
}

// DISPLAYCONFIG_VIDEO_SIGNAL_INFO (48 bytes). The video standard union is kept as its plain value.
struct VideoSignalInfo
{
	ulong pixel_rate;
	Rational h_sync;
	Rational v_sync;
	Region active_size;
	Region total_size;
	uint video_standard;
	uint scan_line_ordering;
}

// DISPLAYCONFIG_SOURCE_MODE (20 bytes): the desktop size and the place of the source in the layout.
struct SourceMode
{
	uint width;
	uint height;
	uint pixel_format;
	int position_x;
	int position_y;
}

// DISPLAYCONFIG_MODE_INFO (64 bytes): a header, then a source or target mode (or a desktop image info,
// which this backend does not read). The payload is 48 bytes, the size of the largest member.
struct ModeInfo
{
	uint info_type;
	uint id;
	Luid adapter;
	char[48] payload;
}

// DISPLAYCONFIG_PATH_SOURCE_INFO (20 bytes).
struct PathSource
{
	Luid adapter;
	uint id;
	uint mode_info;
	uint status_flags;
}

// DISPLAYCONFIG_PATH_TARGET_INFO (48 bytes).
struct PathTarget
{
	Luid adapter;
	uint id;
	uint mode_info;
	uint output_technology;
	uint rotation;
	uint scaling;
	Rational refresh_rate;
	uint scan_line_ordering;
	int available;
	uint status_flags;
}

// DISPLAYCONFIG_PATH_INFO (72 bytes).
struct PathInfo
{
	PathSource source;
	PathTarget target;
	uint flags;
}

// DISPLAYCONFIG_DEVICE_INFO_HEADER (20 bytes): what a DisplayConfigGetDeviceInfo request names.
struct DeviceInfoHeader
{
	uint info_type;
	uint size;
	Luid adapter;
	uint id;
}

// DISPLAYCONFIG_SOURCE_DEVICE_NAME: the GDI device name of a source, such as \\.\DISPLAY1.
struct SourceDeviceName
{
	DeviceInfoHeader header;
	Char16[CCH_DEVICE_NAME] gdi_name;
}

// DISPLAYCONFIG_TARGET_DEVICE_NAME: the monitor's device path, which names it stably, and its friendly name.
struct TargetDeviceName
{
	DeviceInfoHeader header;
	uint flags;
	uint output_technology;
	ushort edid_manufacture_id;
	ushort edid_product_code_id;
	uint connector_instance;
	Char16[64] friendly_name;
	Char16[128] device_path;
}

extern fn int get_display_config_buffer_sizes(
	uint flags,
	uint* paths,
	uint* modes
) @cname("GetDisplayConfigBufferSizes");
extern fn int query_display_config(
	uint flags,
	uint* paths,
	PathInfo* path_array,
	uint* modes,
	ModeInfo* mode_array,
	void* topology
) @cname("QueryDisplayConfig");
extern fn int set_display_config(
	uint paths,
	PathInfo* path_array,
	uint modes,
	ModeInfo* mode_array,
	uint flags
) @cname("SetDisplayConfig");
extern fn int display_config_get_device_info(DeviceInfoHeader* request) @cname("DisplayConfigGetDeviceInfo");
extern fn int enum_display_settings_ex(
	Char16* device,
	uint mode_index,
	Win32_DEVMODEW* devmode,
	uint flags
) @cname("EnumDisplaySettingsExW");