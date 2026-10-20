# bleu_win: Windows infrastructure for Bleu

`bleu::win` is the layer every Windows backend of a Bleu service builds on: COM and
its apartments, WinRT bring-up, HSTRING and BSTR, UTF-16 at the boundary, the
registry, a hidden message window with typed events, Terminal Services session state,
and a few process facts. It contains no service and no audio, network or display backend.

**Status: compiled only.** Nothing in the Windows code has been executed, here or
anywhere else; no Windows machine was available. `tools/check.sh bleu_core bleu_rt bleu_win`
type-checks the library for all six targets, and the Windows parts are checked against the
standard library's Win32 bindings. The platform-neutral parts (GUID parsing and formatting,
WinRT parameterized IIDs, the HRESULT mapping, UTF-16 conversion, message decoding and the
application message allocator, the registered-message range) were run on Linux: 31 `@test` functions pass under `c3c compile-test`. Every layout, constant and vtable slot is
cited in `docs/research/bleu_win.md`.

## Public API

| Module | What it gives |
| --- | --- |
| `bleu::win::guid` | `Guid`, `make(11 fields)`, `guid("...")` compile-time literal, `parse`, `format`, `equals`, `compare` |
| `bleu::win::hresult` | `Hresult`, `failed`, `succeeded`, `to_fault`, `win32_to_fault`, codes |
| `bleu::win::pinterface` | `instance(piid, args)` IIDs of generic WinRT types, `derive`, `PIID_*`, `SIG_*` |
| `bleu::win::text` | `WideZ`, `to_wide`, `from_wide`, `from_wide_units` |
| `bleu::win::errors` | `raise_hresult`, `raise_win32`, `raise_last`, `system_message` (records `Domain.WIN32`) |
| `bleu::win::com` | `IUnknown`, `Apartment` `enter`/`leave` (STA or MTA), `CLSCTX_*`, `IID_*` |
| `bleu::win::com_ptr` | `Com{T}` owning pointer, `co_create_instance{T}`, `query_interface{S,T}` |
| `bleu::win::com_shell` | `Shell{Vtbl}`, `create`, the three `IUnknown` slots for callbacks you implement |
| `bleu::win::winrt` | `enter`/`leave` (`RoInitialize`), `activation_factory{T}`, `IInspectable`, `IAsyncInfo`, `wait_async` |
| `bleu::win::hstring` | `Hstring`: `create`, `close`, `to_string` |
| `bleu::win::bstr` | `Bstr`: `create`, `close`, `to_string` |
| `bleu::win::registry` | `Key`: `open(hive, path, view, access)`, `dword`, `qword`, `string`, `multi_string`, `binary`, `subkeys`, `values`, `set_dword`, `set_qword`, `set_string`; `watch_key` gives a `Watch` whose `handle()` feeds `bleu::rt`'s poller |
| `bleu::win::message_loop` | `open(allocator, handler, context)` → `Loop` (hidden window), `post_wake`, `allocate_message` (application message ids), `register_named_message` (ids such as TaskbarCreated), `add_clipboard_listener`/`remove_clipboard_listener`, `register_hotkey`/`unregister_hotkey`, `watch_power`, `watch_devices`, `pump(timeout)`, `dispatch_pending`; `Event` kinds: `POWER_SETTING`, `POWER_STATE`, `DISPLAY_CHANGE`, `DEVICE_CHANGE`, `SESSION_CHANGE`, `SETTING_CHANGE`, `DPI_CHANGE`, `WAKE`, `CUSTOM_MESSAGE` (`message`, `wparam`, `lparam`), `CLIPBOARD_UPDATED`, `HOTKEY` (`hotkey_id`, `modifiers`, `vk`); every event has `time` (milliseconds, `GetMessageTime`) |
| `bleu::win::session` | `register`/`unregister` (WTS session notifications), `is_locked(session)` |
| `bleu::win::process` | `is_elevated`, `current_user_sid`, `query_image_name`, `wts_session_id`, `locked_workstation` |

Two conventions to know. C3 has no static methods, so constructors and parsers are free
functions (`guid::parse`, `registry::open`). Generic functions are called with their type
arguments, as in `com_ptr::query_interface{Source, Target}(&source, iid)`.

## Example: an `IMMNotificationClient` callback

This is the whole pattern for a native callback object: a vtable, a shell, a callback that
runs inside `@foreign_entry`, and registration with the system. It compiles for
`windows-x64` and `windows-aarch64`. It is not run, and it is not part of the library.

```c3
module notify_example @feat(WIN32);
import std::os::win32;
import bleu::error, bleu::rt::foreign;
import bleu::win::com, bleu::win::com_ptr, bleu::win::com_shell, bleu::win::errors;
import bleu::win::guid, bleu::win::hresult, bleu::win::text;

// IMMNotificationClient (mmdeviceapi.h), IID 7991EEC9-7E89-4D85-8390-6C703CEC60C0.
// Slots: IUnknown 0-2, OnDeviceStateChanged 3, OnDeviceAdded 4, OnDeviceRemoved 5,
// OnDefaultDeviceChanged 6, OnPropertyValueChanged 7.
const Guid IID_IMMNOTIFICATIONCLIENT = guid::guid("7991eec9-7e89-4d85-8390-6c703cec60c0");

alias OnDeviceStateChangedFn = fn hresult::Hresult(void* self, Char16* device_id, uint new_state);
alias OnDeviceAddedFn = fn hresult::Hresult(void* self, Char16* device_id);
alias OnDeviceRemovedFn = fn hresult::Hresult(void* self, Char16* device_id);
alias OnDefaultDeviceChangedFn = fn hresult::Hresult(void* self, int flow, int role, Char16* device_id);
alias OnPropertyValueChangedFn = fn hresult::Hresult(void* self, Char16* device_id, void* key);

struct IMMNotificationClientVtbl
{
	com::QueryInterfaceFn query_interface;
	com::AddRefFn add_ref;
	com::ReleaseFn release;
	OnDeviceStateChangedFn on_device_state_changed;
	OnDeviceAddedFn on_device_added;
	OnDeviceRemovedFn on_device_removed;
	OnDefaultDeviceChangedFn on_default_device_changed;
	OnPropertyValueChangedFn on_property_value_changed;
}

// The owner's side: a callback and its data. The shell's context points here.
alias OnState = fn void(void* owner, String device_id, uint state);
struct Listener
{
	OnState on_state;
	void* owner;
}

alias NotifyShell = com_shell::Shell{IMMNotificationClientVtbl};

fn hresult::Hresult on_device_state_changed(void* self, Char16* device_id, uint new_state)
{
	foreign::@foreign_entry()
	{
		Listener* listener = (Listener*)com_shell::from_this{IMMNotificationClientVtbl}(self).context;
		String id = text::from_wide(tmem, (WString)device_id) ?? "";
		listener.on_state(listener.owner, id, new_state);
	};
	return (hresult::Hresult)hresult::S_OK;
}

// The other notifications are not used by this example; they succeed and do nothing.
fn hresult::Hresult on_device_added(void* self, Char16* device_id) => (hresult::Hresult)hresult::S_OK;
fn hresult::Hresult on_device_removed(void* self, Char16* device_id) => (hresult::Hresult)hresult::S_OK;
fn hresult::Hresult on_default_device_changed(void* self, int flow, int role, Char16* device_id) => (hresult::Hresult)hresult::S_OK;
fn hresult::Hresult on_property_value_changed(void* self, Char16* device_id, void* key) => (hresult::Hresult)hresult::S_OK;

const IMMNotificationClientVtbl NOTIFY_TABLE = {
	.query_interface = &com_shell::query_interface{IMMNotificationClientVtbl},
	.add_ref = &com_shell::add_ref{IMMNotificationClientVtbl},
	.release = &com_shell::release{IMMNotificationClientVtbl},
	.on_device_state_changed = &on_device_state_changed,
	.on_device_added = &on_device_added,
	.on_device_removed = &on_device_removed,
	.on_default_device_changed = &on_default_device_changed,
	.on_property_value_changed = &on_property_value_changed,
};

// IMMDeviceEnumerator (mmdeviceapi.h): class BCDE0395-E52F-467C-8E3D-C4579291692E,
// IID A95664D2-9614-4F35-A746-DE8DB63617E6. Slots 6 and 7 are the registration pair.
const Guid CLSID_MMDEVICE_ENUMERATOR = guid::guid("bcde0395-e52f-467c-8e3d-c4579291692e");
const Guid IID_IMMDEVICE_ENUMERATOR = guid::guid("a95664d2-9614-4f35-a746-de8db63617e6");

alias RegisterCallbackFn = fn hresult::Hresult(void* self, void* client);

struct IMMDeviceEnumeratorVtbl
{
	com::QueryInterfaceFn query_interface;
	com::AddRefFn add_ref;
	com::ReleaseFn release;
	void* enum_audio_endpoints;
	void* get_default_audio_endpoint;
	void* get_device;
	RegisterCallbackFn register_endpoint_notification_callback;
	RegisterCallbackFn unregister_endpoint_notification_callback;
}

struct IMMDeviceEnumerator
{
	IMMDeviceEnumeratorVtbl* vtbl;
}

<* Register `shell` with the system's device enumerator. The shell's own reference is given up on success. *>
fn com_ptr::Com{IMMDeviceEnumerator}? start(NotifyShell* shell)
{
	com_ptr::Com{IMMDeviceEnumerator} enumerator = com_ptr::co_create_instance{IMMDeviceEnumerator}(CLSID_MMDEVICE_ENUMERATOR, IID_IMMDEVICE_ENUMERATOR)!;
	hresult::Hresult hr = (hresult::Hresult)enumerator.ptr.vtbl.register_endpoint_notification_callback(enumerator.ptr, shell);
	if (hr.failed())
	{
		shell.vtbl.release(shell);
		enumerator.release();
		return errors::raise_hresult(hr, "RegisterEndpointNotificationCallback")~;
	}
	shell.vtbl.release(shell);
	return enumerator;
}

<* Unregister. The enumerator releases the shell's last reference, which frees it. *>
fn void? stop(com_ptr::Com{IMMDeviceEnumerator}* enumerator, NotifyShell* shell)
{
	hresult::Hresult hr = (hresult::Hresult)enumerator.ptr.vtbl.unregister_endpoint_notification_callback(enumerator.ptr, shell);
	enumerator.release();
	if (hr.failed()) return errors::raise_hresult(hr, "UnregisterEndpointNotificationCallback")~;
}

<* Create a shell whose callbacks go to `listener`. Its only reference belongs to `start`. *>
fn NotifyShell* new_shell(Listener* listener)
{
	return com_shell::create{IMMNotificationClientVtbl}(mem, &NOTIFY_TABLE, IID_IMMNOTIFICATIONCLIENT, true, listener);
}
```

The vtable slot order (IUnknown 0-2, then the five notifications 3-7) and the IID are cited in
`docs/research/bleu_win.md`, section 3. `start` consumes the shell's creation reference after
the enumerator has taken its own, so `stop` frees the shell.

## Threads and ownership

* COM and WinRT are initialised per thread (`com::enter`, `winrt::enter`) and must be left on that thread.
* Native callbacks arrive on foreign threads. Their bodies run in `bleu::rt::foreign::@foreign_entry`,
  because the temporary allocator is not available there (C3 0.8.5 aborts otherwise).
* A `message_loop.Loop` belongs to the thread that opened it. `post_wake` is the only cross-thread call.
  `Event.text` is valid only during the callback.
* `Hstring`, `Bstr`, `WideZ` and registry values own their memory; each has a `close`/`free`.
* `Watch` takes ownership of its key and event; `handle()` is valid until `close`.

## What is NOT done

* No WLAN, WinRT media, notification, display-configuration or power-management backend. These
  are for the services that use this library.
* Nothing has run on Windows. Import library names (`ole32`, `runtimeobject`, `oleaut32`,
  `advapi32`, `user32`, `wtsapi32`) were not checked by a linker.
* `wait_async` returns the status. The result is left to the operation's `GetResults`.
* The lock check requires Windows 8 or later (Windows 7 reverses the flags).
* The message window is a hidden top-level window, not `HWND_MESSAGE`, because message-only
  windows do not receive the broadcast messages this module needs. Learn documents this; no test confirms it.
* `Registry`: no `RegDeleteValue`, no key creation, no `REG_EXPAND_SZ` expansion.
* `IAgileObject` is answered by the shell, but whether MMDevice treats a shell as agile has not been observed.
* The temporary-allocator wrappers for callbacks allocate a 64 KiB pool per entry (`bleu_rt`).
* Hot keys: `RegisterHotKey` reports the press only (no key-up). A loop refuses an id it already holds
  (`INVALID_STATE`), and `close` unregisters the hot keys it still holds.
* Application message ids are per loop and are never reused; an exhausted range is `CAPACITY_EXCEEDED`.
* `Event.time` is `GetMessageTime` at dispatch. For a message that was sent rather than posted (system
  broadcasts), it is the time of the last message the loop retrieved, not the time it was sent. Not run.
* The `RegisterWindowMessageW` range 0xC000 through 0xFFFF is cited from Learn only.
* The clipboard listener, hot keys and application messages are compiled only (see section 13 of
  `docs/research/bleu_win.md`).

See `docs/research/bleu_win.md` for every cited value, the vtable tables, and the open risks.
