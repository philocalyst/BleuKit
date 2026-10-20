<*
 Power-setting and device-interface notifications for a `Loop`'s window.
 Part of `bleu::win::message_loop`; they arrive as `POWER_SETTING` and
 `DEVICE_CHANGE` events.

 Sources: `RegisterPowerSettingNotification` (winuser.h; Learn: "Registers the
 application to receive power setting notifications ... DEVICE_NOTIFY_WINDOW_HANDLE
 ... notifications are sent using WM_POWERBROADCAST messages"), and
 `RegisterDeviceNotificationW` with `DEV_BROADCAST_DEVICEINTERFACE_W` (winuser.h,
 dbt.h; Learn "RegisterDeviceNotificationW").
*>
module bleu::win::message_loop @feat(WIN32) @link("user32");
import std::os::win32;
import bleu::error;
import bleu::win::errors, bleu::win::guid;

<* `DEVICE_NOTIFY_WINDOW_HANDLE` (winuser.h): notifications are posted to a window handle. *>
const uint DEVICE_NOTIFY_WINDOW_HANDLE = 0x00000000;

extern fn void* registerPowerSettingNotification(
	void* recipient,
	Guid* setting,
	uint flags
) @cname("RegisterPowerSettingNotification");
extern fn Win32_BOOL unregisterPowerSettingNotification(void* handle) @cname("UnregisterPowerSettingNotification");
extern fn void* registerDeviceNotificationW(
	void* recipient,
	void* filter,
	uint flags
) @cname("RegisterDeviceNotificationW");
extern fn Win32_BOOL unregisterDeviceNotification(void* handle) @cname("UnregisterDeviceNotification");

<* A registration for one power setting. Undo with `close`. *>
struct PowerWatch
{
	void* handle;
}

<* A registration for one device interface class. Undo with `close`. *>
struct DeviceWatch
{
	void* handle;
}

<*
 Ask for `POWER_SETTING` events when power setting `setting` changes, such as
 `GUID_ACDC_POWER_SOURCE` (winnt.h).

 @return? error::BACKEND_FAILURE : "RegisterPowerSettingNotification failed"
*>
fn PowerWatch? Loop.watch_power(&self, Guid setting)
{
	void* handle = registerPowerSettingNotification(self.window, &setting, DEVICE_NOTIFY_WINDOW_HANDLE);
	if (!handle) return errors::raise_last("RegisterPowerSettingNotification")~;
	return { .handle = handle };
}

<* Stop the power setting notifications. Returns the failure, if the system reports one. *>
fn void? PowerWatch.close(&self)
{
	if (self.handle && unregisterPowerSettingNotification(self.handle) == 0)
	{
		return errors::raise_last("UnregisterPowerSettingNotification")~;
	}
	self.handle = null;
}

<*
 Ask for `DEVICE_CHANGE` events when device interfaces of class `interface_class`
 arrive or are removed (for example `DEVINTERFACE_AUDIO_RENDER`).

 @return? error::BACKEND_FAILURE : "RegisterDeviceNotificationW failed"
*>
fn DeviceWatch? Loop.watch_devices(&self, Guid interface_class)
{
	DeviceInterfaceBroadcast filter = {
		.size = DeviceInterfaceBroadcast::size,
		.device_type = DBT_DEVTYP_DEVICEINTERFACE,
		.class_guid = interface_class,
	};
	void* handle = registerDeviceNotificationW(self.window, &filter, DEVICE_NOTIFY_WINDOW_HANDLE);
	if (!handle) return errors::raise_last("RegisterDeviceNotificationW")~;
	return { .handle = handle };
}

<* Stop the device notifications. Returns the failure, if the system reports one. *>
fn void? DeviceWatch.close(&self)
{
	if (self.handle && unregisterDeviceNotification(self.handle) == 0)
	{
		return errors::raise_last("UnregisterDeviceNotification")~;
	}
	self.handle = null;
}