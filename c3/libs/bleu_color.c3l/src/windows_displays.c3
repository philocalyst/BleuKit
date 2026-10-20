<*
 The displays the desktop shows: `EnumDisplayDevicesW`, used to list the attached display devices
 of the session. Declarations from the Windows SDK, as the Microsoft Learn pages for
 EnumDisplayDevicesW and DISPLAY_DEVICEW state them (docs/research/color_impl.md, section 4).

 COMPILED ONLY: type-checked for Windows, never run.
*>
module bleu::color::windows_displays @feat(WIN32) @link("user32");

<*
 `DISPLAY_DEVICE_ATTACHED_TO_DESKTOP`: the device is part of the desktop. Wine's wingdi.h defines it
 as 0x00000001, the same value the Microsoft page for DISPLAY_DEVICE gives in its StateFlags table.
*>
const uint ATTACHED_TO_DESKTOP = 0x00000001;

<*
 `sizeof(DISPLAY_DEVICEW)`: cb (4) + DeviceName[32] + DeviceString[128] (2 bytes each) + StateFlags (4)
 + DeviceID[128] + DeviceKey[128]: 4 + 64 + 256 + 4 + 256 + 256 = 840 bytes, with no padding.
*>
const uint DISPLAY_DEVICE_SIZE = 840;

<* `DISPLAY_DEVICEW` (wingdi.h): one display device of the session, UTF-16 strings. *>
struct DisplayDeviceW
{
	uint cb;
	ushort[32] device_name;
	ushort[128] device_string;
	uint state_flags;
	ushort[128] device_id;
	ushort[128] device_key;
}

extern fn int enumDisplayDevicesW(void* device, uint index, DisplayDeviceW* out, uint flags) @cname("EnumDisplayDevicesW");
