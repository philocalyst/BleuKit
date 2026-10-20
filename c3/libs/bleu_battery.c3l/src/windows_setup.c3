<*
 Enumerating battery device interfaces with SetupAPI.

 Every battery device exposes the battery device interface class, whose GUID is
 GUID_DEVCLASS_BATTERY = {72631E54-78A4-11D0-BCF7-00AA00B7B32A} (GUID_DEVICE_BATTERY
 has the same value). Enumeration is the first of the two steps in starship-battery
 0.10.0 `src/platform/windows/ffi/mod.rs`; the second is `windows_ioctl.c3`.

 Sources: SetupAPI.h, which `windows-sys` 0.59.0 mirrors in
 `Win32::Devices::DeviceAndDriverInstallation` (declarations, flags, and the
 `repr(C, packed(1))` on SP_DEVICE_INTERFACE_DATA and SP_DEVICE_INTERFACE_DETAIL_DATA_W,
 which matches `#pragma pack(1)` in SetupAPI.h); the GUID value is the same in both.
*>
module bleu::battery::win32 @feat(WIN32) @link("setupapi");
import std::os::win32, bleu::error, bleu::win::errors, bleu::win::guid, bleu::win::text;

<* GUID_DEVCLASS_BATTERY (SetupAPI.h, batclass.h). *>
const Guid BATTERY_CLASS = guid::guid("72631e54-78a4-11d0-bcf7-00aa00b7b32a");

// SetupAPI flags (SetupAPI.h; windows-sys: DIGCF_PRESENT = 2, DIGCF_DEVICEINTERFACE = 16).
const uint DIGCF_PRESENT         = 0x00000002;
const uint DIGCF_DEVICEINTERFACE = 0x00000010;

// Win32 error codes (winerror.h; windows-sys: 259 and 122).
const uint ERROR_NO_MORE_ITEMS       = 259;
const uint ERROR_INSUFFICIENT_BUFFER = 122;

// SP_DEVICE_INTERFACE_DETAIL_DATA_W with pack(1): a DWORD cbSize and one WCHAR, 6 bytes.
// The path starts at byte 4 of the detail buffer (windows-sys: `DevicePath: [u16; 1]`).
const uint DETAIL_CB_SIZE   = 6;
const sz DETAIL_PATH_OFFSET = 4;

extern fn Win32_HANDLE setup_di_get_class_devs_w(
	Guid* class_guid,
	WString enumerator,
	void* parent,
	uint flags
) @cname("SetupDiGetClassDevsW");
extern fn Win32_BOOL setup_di_enum_device_interfaces(
	Win32_HANDLE device_info,
	void* device_data,
	Guid* class_guid,
	uint index,
	DeviceInterfaceData* data
) @cname("SetupDiEnumDeviceInterfaces");
extern fn Win32_BOOL setup_di_get_device_interface_detail_w(
	Win32_HANDLE device_info,
	DeviceInterfaceData* data,
	void* detail,
	uint detail_size,
	uint* required,
	void* device_data
) @cname("SetupDiGetDeviceInterfaceDetailW");
extern fn Win32_BOOL setup_di_destroy_device_info_list(Win32_HANDLE device_info) @cname("SetupDiDestroyDeviceInfoList");

<*
 SP_DEVICE_INTERFACE_DATA (SetupAPI.h). 32 bytes; the natural alignment of its fields
 matches the packed layout, so no padding is inserted.
*>
struct DeviceInterfaceData
{
	uint cb_size;
	Guid interface_class;
	uint flags;
	ulong reserved;
}

<* The battery device set (an HDEVINFO), owned until `close`. *>
struct DeviceSet
{
	Win32_HANDLE handle;
}

<*
 Every present battery device interface.

 @return? error::BACKEND_FAILURE : "when SetupAPI cannot enumerate the battery class"
*>
fn DeviceSet? battery_devices()
{
	Win32_HANDLE handle = setup_di_get_class_devs_w(&BATTERY_CLASS, null, null, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
	if (handle == win32::INVALID_HANDLE_VALUE) return errors::raise_last("SetupDiGetClassDevsW")~;
	return { .handle = handle };
}

<* Destroy the device set. Idempotent. *>
fn void DeviceSet.close(&self)
{
	if (self.handle == null) return;
	// The result is not needed: the handle is gone either way.
	(void)setup_di_destroy_device_info_list(self.handle);
	self.handle = null;
}

<*
 The device path of the `index`-th battery interface, in temporary memory.

 @return? NO_MORE_ELEMENT : "past the last battery interface"
 @return? error::BACKEND_FAILURE : "when SetupAPI cannot read the path"
*>
fn String? DeviceSet.path(&self, uint index)
{
	DeviceInterfaceData data = { .cb_size = DeviceInterfaceData::size };
	if (!setup_di_enum_device_interfaces(self.handle, null, &BATTERY_CLASS, index, &data))
	{
		if (win32::getLastError() == ERROR_NO_MORE_ITEMS) return NO_MORE_ELEMENT~;
		return errors::raise_last("SetupDiEnumDeviceInterfaces")~;
	}
	// First call: learn the buffer size. It fails with ERROR_INSUFFICIENT_BUFFER by design.
	uint needed = 0;
	setup_di_get_device_interface_detail_w(self.handle, &data, null, 0, &needed, null);
	if (win32::getLastError() != ERROR_INSUFFICIENT_BUFFER || needed <= DETAIL_PATH_OFFSET)
	{
		return errors::raise_last("SetupDiGetDeviceInterfaceDetailW (size)")~;
	}
	char[] buffer = alloc::new_array(tmem, char, (sz)needed);
	*(uint*)buffer.ptr = DETAIL_CB_SIZE;
	if (!setup_di_get_device_interface_detail_w(self.handle, &data, buffer.ptr, needed, &needed, null))
	{
		return errors::raise_last("SetupDiGetDeviceInterfaceDetailW")~;
	}
	return text::from_wide(tmem, (WString)&buffer[DETAIL_PATH_OFFSET]);
}