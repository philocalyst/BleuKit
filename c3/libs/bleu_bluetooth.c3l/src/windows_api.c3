<*
 The Win32 Bluetooth functions (bluetoothapis.h), resolved at run time.

 The functions are documented in bluetoothapis.h with import library
 Bthprops.lib, and windows-sys places them in bluetoothapis.dll, while it places
 only the authentication functions in bthprops.cpl. Both names are tried, in
 that order, so the library works whichever one the system provides; the
 discrepancy is recorded in docs/research/bluetooth.md section 4.

 Signatures and structure layouts: windows-sys 0.61.2
 (Windows::Win32::Devices::Bluetooth, mod.rs:7-47, 206-216, 340-347) and the
 Learn pages for BluetoothFindFirstRadio, BluetoothFindFirstDevice,
 BluetoothRemoveDevice (docs/research/bluetooth.md section 2.3).
*>
module bleu::bluetooth::win32_api @feat(WIN32);
import bleu::dl, bleu::dl::lazy;

<* The libraries that may export the Bluetooth functions, in the order they are tried. *>
const String[2] BLUETOOTH_LIBRARIES = { "bluetoothapis.dll", "bthprops.cpl" };

<* BLUETOOTH_FIND_RADIO_PARAMS: the size of the structure, then nothing. *>
struct FindRadioParams
{
	uint size;
}

<* BLUETOOTH_RADIO_INFO. `name` is UTF-16, NUL-terminated within its 248 units. *>
struct RadioInfo
{
	uint size;
	ulong address;
	Char16[248] name;
	uint class_of_device;
	ushort lmp_subversion;
	ushort manufacturer;
}

<* BLUETOOTH_DEVICE_SEARCH_PARAMS. `radio` is the radio to search, or null for all radios. *>
struct DeviceSearchParams
{
	uint size;
	int return_authenticated;
	int return_remembered;
	int return_unknown;
	int return_connected;
	int issue_inquiry;
	char timeout_multiplier;
	void* radio;
}

<* BLUETOOTH_DEVICE_INFO. Two SYSTEMTIME values (eight words each) sit between the flags and the name. *>
struct DeviceInfo
{
	uint size;
	ulong address;
	uint class_of_device;
	int connected;
	int remembered;
	int authenticated;
	ushort[8] last_seen;
	ushort[8] last_used;
	Char16[248] name;
}

alias FindFirstRadioFn = fn void*(FindRadioParams* params, void** radio);
alias FindNextRadioFn = fn int(void* find, void** radio);
alias FindRadioCloseFn = fn int(void* find);
alias GetRadioInfoFn = fn uint(void* radio, RadioInfo* info);
alias FindFirstDeviceFn = fn void*(DeviceSearchParams* params, DeviceInfo* info);
alias FindNextDeviceFn = fn int(void* find, DeviceInfo* info);
alias FindDeviceCloseFn = fn int(void* find);
alias RemoveDeviceFn = fn uint(ulong* address);

<* The bound functions. A missing one leaves the whole table unbound. *>
struct Api
{
	FindFirstRadioFn find_first_radio @tag("sym", "BluetoothFindFirstRadio");
	FindNextRadioFn find_next_radio @tag("sym", "BluetoothFindNextRadio");
	FindRadioCloseFn find_radio_close @tag("sym", "BluetoothFindRadioClose");
	GetRadioInfoFn get_radio_info @tag("sym", "BluetoothGetRadioInfo");
	FindFirstDeviceFn find_first_device @tag("sym", "BluetoothFindFirstDevice");
	FindNextDeviceFn find_next_device @tag("sym", "BluetoothFindNextDevice");
	FindDeviceCloseFn find_device_close @tag("sym", "BluetoothFindDeviceClose");
	RemoveDeviceFn remove_device @tag("sym", "BluetoothRemoveDevice");
}

// Bound once per process on first use; a failed bind is kept and reported to every caller.
lazy::Lazy{Api} api_table;

<* The bound Win32 functions, or the excuse why they are not there. *>
fn Api*? api()
{
	return api_table.get(BLUETOOTH_LIBRARIES[..]);
}