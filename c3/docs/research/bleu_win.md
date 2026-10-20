# bleu_win: research and verification record

Scope: `libs/bleu_win.c3l` (module root `bleu::win`). Every native layout, constant,
GUID, vtable slot order and signature used by the library is listed below with the
sources it was checked against. Nothing here was executed on Windows: the Windows
code is type-checked by `tools/check.sh` for `windows-x64` and `windows-aarch64`
against the standard library's Win32 bindings (`/opt/c3/c3/lib/std/os/win32`), and
the platform-neutral parts were run on Linux (`c3c compile-test`, 22 tests:
`guid_test.c3`, `pinterface_test.c3`, `hresult_test.c3`, `text_test.c3`, `message_codes_test.c3`).
The count was 22 when first written; 24 `@test`s ran before the message-loop additions of section 7, and 30 run now.

## Source shorthand

| Tag | Source | Where it was read |
| --- | --- | --- |
| **M** | mingw-w64 headers, `mingw-w64-headers/include/*.h` (MIDL- and SDK-derived) | `raw.githubusercontent.com/mingw-w64/mingw-w64/master/...` |
| **W** | Wine headers and IDL, `include/*.h`, `include/*.idl` | `raw.githubusercontent.com/wine-mirror/wine/master/...` |
| **L** | Microsoft Learn page (URL given) | `learn.microsoft.com` |
| **R** | Rust crates from crates.io: `windows` 0.62.2, `windows-core` 0.62.2, `windows-future` 0.100.0, `windows-collections` 0.100.0, `winapi` 0.3.9 (hand-written from the SDK headers, an independent source) | `static.crates.io` |
| **S** | the standard library in `/opt/c3/c3/lib/std` | local |

Two independent sources are cited for each native fact unless marked **(one source)**.

## 1. GUIDs

* Layout: `struct Guid { uint data1; ushort data2; ushort data3; char[8] data4; }`,
  16 bytes, 4-byte alignment. **M** `guiddef.h` (`GUID`), **R** `windows-core` `src/guid.rs`
  (`from_values`, `from_u128`: data1 = bits 127..96, data2 = 95..80, data3 = 79..64, data4 big-endian).
  Checked at compile time (`$assert(Guid::size == 16)`) and by `guid_layout_is_sixteen_bytes`.
* Text form and the 11-field literal form: **M** `DEFINE_GUID(name, 0x..., 0x..., 0x..., 0x.., ...)`.
  `guid("...")` is a compile-time macro (`guid.c3`): it parses the text while the compiler folds
  the constant, so `const Guid X = guid("...")` works. Tested by `guid_literal_matches_fields`.
* The constants used by the library, each checked in both M and W:

| Name | Value | Sources |
| --- | --- | --- |
| `IID_IUnknown` | 00000000-0000-0000-C000-000000000046 | M `unknwn.h` (`MIDL_INTERFACE`), W `unknwn.idl` (`uuid(00000000-0000-0000-C000-000000000046)`) |
| `IID_IAgileObject` | 94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90 | M `objidl.h` (`DEFINE_GUID(IID_IAgileObject, ...)`); R `winapi` 0.3.9 `src/um/objidlbase.rs:60` (`#[uuid(0x94ea2b94, ...)]`, `interface IAgileObject: IUnknown {}`). Not in W. |
| `IID_IInspectable` | AF86E2E0-B12D-4C6A-9C5A-D7AA65101E90 | M `inspectable.h` (`DEFINE_GUID`), W `inspectable.idl` (`uuid(af86e2e0-...)`) |
| `IID_IAsyncInfo` | 00000036-0000-0000-C000-000000000046 | M `asyncinfo.h` (`MIDL_INTERFACE`), W `asyncinfo.idl` |
| `IID_IMMNotificationClient` | 7991EEC9-7E89-4D85-8390-6C703CEC60C0 | M `mmdeviceapi.h` (`DEFINE_GUID`), W `mmdeviceapi.idl` |
| `CLSID_MMDeviceEnumerator` | BCDE0395-E52F-467C-8E3D-C4579291692E | M `mmdeviceapi.h` (`DEFINE_GUID`), W `mmdeviceapi.idl` (coclass) |
| `IID_IMMDeviceEnumerator` | A95664D2-9614-4F35-A746-DE8DB63617E6 | M `mmdeviceapi.h`, W `mmdeviceapi.idl` |
| Power setting GUIDs (`GUID_ACDC_POWER_SOURCE`, `GUID_BATTERY_PERCENTAGE_REMAINING`, `GUID_CONSOLE_DISPLAY_STATE`, `GUID_SESSION_DISPLAY_STATUS`, `GUID_SESSION_USER_PRESENCE`) | see section 11 | M `winnt.h` (`DEFINE_GUID`), **L** "Power setting GUIDs" (`learn.microsoft.com/en-us/windows/win32/power/power-setting-guids`) |

## 2. HRESULTs and Win32 error codes

All values were compared line by line between **M** `winerror.h` and **W** `include/winerror.h`; they agree.

| Constant | Value | Notes |
| --- | --- | --- |
| `S_OK`, `S_FALSE` | 0, 1 | |
| `E_NOINTERFACE`, `E_NOTIMPL`, `E_FAIL`, `E_POINTER` | 0x80004002, 0x80004001, 0x80004005, 0x80004003 | M and W `winerror.h` agree |
| `E_ACCESSDENIED` | 0x80070005 | = `HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED)` |
| `E_OUTOFMEMORY` | 0x8007000E | = `HRESULT_FROM_WIN32(ERROR_OUTOFMEMORY)` |
| `E_INVALIDARG` | 0x80070057 | = `HRESULT_FROM_WIN32(ERROR_INVALID_PARAMETER)` |
| `RPC_E_CHANGED_MODE` | 0x80010106 | **L** `CoInitializeEx` and `RoInitialize` return tables |
| `RPC_E_DISCONNECTED` | 0x80010108 | |
| `RPC_S_SERVER_UNAVAILABLE` | 1722 | a Win32 code |
| `FACILITY_WIN32` | 7 | |
| `HRESULT_FROM_WIN32(x)` | `x <= 0 ? x : (x & 0xFFFF) \| (7 << 16) \| 0x80000000` | **M** `winerror.h` macro `__HRESULT_FROM_WIN32`; `hresult_test.c3` |
| `ERROR_FILE_NOT_FOUND`, `ERROR_PATH_NOT_FOUND`, `ERROR_NOT_FOUND` | 2, 3, 1168 | |
| `ERROR_ACCESS_DENIED` / `ERROR_NOT_ENOUGH_MEMORY` / `ERROR_OUTOFMEMORY` | 5 / 8 / 14 | |
| `ERROR_INVALID_PARAMETER` / `ERROR_NOT_SUPPORTED` | 87 / 50 | |
| `ERROR_BUSY` / `ERROR_CANCELLED` | 170 / 1223 | |
| `ERROR_TIMEOUT` / `WAIT_TIMEOUT` | 1460 / 258 | |
| `ERROR_MORE_DATA` / `ERROR_NO_MORE_ITEMS` / `ERROR_INSUFFICIENT_BUFFER` | 234 / 259 / 122 | |
| `ERROR_ALREADY_EXISTS` / `ERROR_CLASS_ALREADY_EXISTS` | 183 / 1410 | |
| `ERROR_HOTKEY_ALREADY_REGISTERED` / `ERROR_HOTKEY_NOT_REGISTERED` | 1409 / 1419 | **M** `winerror.h` lines 1188, 1198; **W** `winerror.h` lines 1232, 1242; **R** `windows-sys` `Foundation/mod.rs` lines 2477-2478; **L** "System Error Codes (1300-1699)": "Hot key is already registered" / "Hot key is not registered" |

Fault mapping (`hresult.c3`, the table the brief specifies): an HRESULT with facility 7 is mapped by its low 16 bits
(`win32_to_fault`), so `E_ACCESSDENIED`, `E_OUTOFMEMORY` and `E_INVALIDARG` reach
`PERMISSION_DENIED`, `NO_MEMORY` and `INVALID_ARGUMENT` through their Win32 codes. The
other HRESULTs are matched by value: `E_NOTIMPL` → `UNSUPPORTED`, `RPC_E_DISCONNECTED` →
`DISCONNECTED`, anything else → `BACKEND_FAILURE`. `ERROR_NOT_FOUND`/`ERROR_FILE_NOT_FOUND`/
`ERROR_PATH_NOT_FOUND` → `NOT_FOUND`; `ERROR_TIMEOUT`/`WAIT_TIMEOUT` → `TIMEOUT`;
`RPC_S_SERVER_UNAVAILABLE` → `DISCONNECTED`. `ERROR_HOTKEY_ALREADY_REGISTERED` → `BUSY` (another
program holds the chord) and `ERROR_HOTKEY_NOT_REGISTERED` → `NOT_FOUND`, both with the Win32 code in the
detail (`errors::raise_win32`). Any other code is `BACKEND_FAILURE`.

Message text: `FormatMessageW` with `FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS`
(`0x1000 | 0x200`; **M** and **W** `winbase.h`). **L** `FormatMessageW`.

## 3. COM: apartments, `IUnknown`, shells

| Item | Value / rule | Sources |
| --- | --- | --- |
| `COINIT_MULTITHREADED` / `COINIT_APARTMENTTHREADED` | 0x0 / 0x2 | **M** `objbase.h`, **W** `objbase.h` |
| `CLSCTX_INPROC_SERVER`, `_INPROC_HANDLER`, `_LOCAL_SERVER`, `_REMOTE_SERVER` | 0x1, 0x2, 0x4, 0x10; `CLSCTX_ALL` = 0x17 | **M** `wtypesbase.h` lines 270-274, **W** `wtypesbase.idl` lines 266-270, R `winapi` `src/shared/wtypesbase.rs:65`; `CLSCTX_ALL` **M** `combaseapi.h` lines 134-136 |
| `CoInitializeEx` | `(LPVOID reserved, DWORD flags)`; `S_OK` and `S_FALSE` both mean the call must be balanced by `CoUninitialize` | **M** `combaseapi.h`; **L** `CoInitializeEx` ("S_FALSE: already initialized on this thread") |
| `CoCreateInstance` | `(REFCLSID, LPUNKNOWN, DWORD, REFIID, LPVOID*)` | **M** `combaseapi.h` line 258; **L** `CoCreateInstance` |
| `CoTaskMemFree` / `CoUninitialize` | `void (LPVOID)` / `void (void)` | **M** `combaseapi.h`; the `windows` crate binds `CoTaskMemFree` to `combase.dll` and the rest to `ole32.dll` (**R**) |

### Slot tables

| Interface | Slot | Method | Source |
| --- | --- | --- | --- |
| `IUnknown` (every vtable in Bleu) | 0 | QueryInterface(REFIID, void**) | **M** `unknwn.h` (`MIDL_INTERFACE`, `QueryInterface`/`AddRef`/`Release` order); **W** `unknwn.idl` `cpp_quote` (same order) |
| | 1 | AddRef(void) → ULONG | same |
| | 2 | Release(void) → ULONG | same |
| `IInspectable` | 3 | GetIids(ULONG*, IID**) | **M** `inspectable.h`; **W** `inspectable.idl` (`[out] ULONG *iidCount, [out, size_is(,*iidCount)] IID **iids`); R `winapi` `src/winrt/inspectable.rs` lines 18-24 |
| | 4 | GetRuntimeClassName(HSTRING*) | same |
| | 5 | GetTrustLevel(TrustLevel*) | same; `TrustLevel` = BaseTrust 0, PartialTrust 1, FullTrust 2 (**W** `inspectable.idl`) |
| `IAsyncInfo` (: IInspectable) | 6 | get_Id(UINT32*) | **M** `asyncinfo.h` (lines 56-68 order: get_Id, get_Status, get_ErrorCode, Cancel, Close); **W** `asyncinfo.idl`; R `windows-future` 0.100.0 `src/bindings.rs` lines 1361-1374 (`IAsyncInfo_Vtbl`: base, Id, Status, ErrorCode, Cancel, Close) |
| | 7 | get_Status(AsyncStatus*) | same; `AsyncStatus` Started 0, Completed 1, Canceled 2, Error 3 (**W** `asyncinfo.idl`) |
| | 8 | get_ErrorCode(HRESULT*) | same |
| | 9 | Cancel(void) | same |
| | 10 | Close(void) | same |
| `IMMNotificationClient` (README example) | 3 | OnDeviceStateChanged(LPCWSTR, DWORD) | **M** `mmdeviceapi.h`; **W** `mmdeviceapi.idl` `[id(1)]`; R `winapi` `src/um/mmdeviceapi.rs` lines 99-120 (same order) |
| | 4 | OnDeviceAdded(LPCWSTR) | same, `[id(2)]` |
| | 5 | OnDeviceRemoved(LPCWSTR) | same, `[id(3)]` |
| | 6 | OnDefaultDeviceChanged(EDataFlow, ERole, LPCWSTR) | same, `[id(4)]` |
| | 7 | OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) | same, `[id(5)]`; `PROPERTYKEY` is 20 bytes, so the x64 ABI passes it by reference: the example uses `void*` |
| `IMMDeviceEnumerator` (README example) | 3 | EnumAudioEndpoints | **M** `mmdeviceapi.h`; **W** `[id(1)]`; R `winapi` `src/um/mmdeviceapi.rs` lines 156-170 |
| | 4 | GetDefaultAudioEndpoint | same, `[id(2)]` |
| | 5 | GetDevice | same, `[id(3)]` |
| | 6 | RegisterEndpointNotificationCallback(IMMNotificationClient*) | same, `[id(4)]` |
| | 7 | UnregisterEndpointNotificationCallback(IMMNotificationClient*) | same, `[id(5)]` |

`IAgileObject` is a marker interface (no methods): the shell answers its IID when it is
created `agile` (callbacks may arrive on any apartment). Shells answer IUnknown and their own
IID; anything else is `E_NOINTERFACE`.

Threading and refcounts: a shell is created with one reference. A registrar that stores the
pointer calls `AddRef`, and calls `Release` on unregistration. Callbacks use `@foreign_entry`
(`bleu::rt::foreign`) because native callbacks arrive on threads that have no temporary
allocator. Sources for the temporary-allocator rule: C3 0.8.5 std (`core/private/allocators_temp.c3`,
the abort message) and the `bleu_rt` foreign-entry notes.

## 4. WinRT bring-up

* `RoInitialize(RO_INIT_TYPE)`: `RO_INIT_SINGLETHREADED` = 0, `RO_INIT_MULTITHREADED` = 1
  (**M** `roapi.h`, **W** `roapi.h`); returns `S_OK`/`S_FALSE`/`RPC_E_CHANGED_MODE` (**L** `RoInitialize`).
  Library: the `windows` crate binds it to `api-ms-win-core-winrt-l1-1-0.dll` (**R**); Learn says `RuntimeObject.lib`
  for the string functions (**L** `WindowsCreateString`, "Library RuntimeObject.lib").
* `RoGetActivationFactory(HSTRING, REFIID, void**)`: **M** `roapi.h` line 33, **W** `roapi.h`.
* `WindowsCreateString(LPCWSTR, UINT32, HSTRING*)`, `WindowsDeleteString(HSTRING)`,
  `WindowsGetStringRawBuffer(HSTRING, UINT32*) → PCWSTR`: **M** `winstring.h` lines 40-52; **W** `winstring.h`.
* `wait_async` polls `IAsyncInfo.get_Status` and pumps the calling thread's messages between
  polls (`MsgWaitForMultipleObjectsEx`), so an STA receives its completion. Rationale: a blocking
  wait on an STA does not dispatch the messages that deliver completions (design note; no
  Learn page is cited for the deadlock, which is an engineering rule, not an API fact).

## 5. Parameterized interface IDs (PIIDs)

**Algorithm** (the test that matters): **L** "WinRT type system", section "Guid generation for
parameterized types" (`learn.microsoft.com/en-us/uwp/winrt-cref/winrt-type-system`):

* namespace `11f47ad5-7b73-42c0-abae-878b1e16adee` (`wrt_pinterface_namespace`), name = signature,
  UUID version 5 (SHA-1, RFC 4122 section 4.3);
* signature grammar: `pinterface({piid};arg1;arg2...)`, the PIID and nested signatures in lower-case dashed braces;
* base types: `b1` Boolean, `i4` Int32, `u4` UInt32, `i8`, `u8`, `f4` Single, `f8` Double, `u1` UInt8,
  `c2` Char16, `string` String, `g16` Guid (same page);
* an interface argument is `{iid}`; IInspectable as an argument is `cinterface(IInspectable)` (same page).

**Implementation cross-check**: **R** `windows-core` 0.62.2 `src/guid.rs` `from_signature`
(namespace bytes `11 f4 7a d5 7b 73 42 c0 ab ae 87 8b 1e 16 ad ee`, SHA-1, data3 `(x & 0x0fff) | 0x5000`,
data4[0] `(x & 0x3f) | 0x80`). The C3 implementation (`pinterface.c3`) follows it.

**PIIDs used** (the `windows` crate's bindings, **R** `windows-future` 0.100.0 `src/bindings.rs`
and `windows-collections` 0.100.0 `src/bindings.rs`, which contain the literal `pinterface({...}` strings):

| Constant | PIID | Crate location |
| --- | --- | --- |
| `PIID_ASYNC_OPERATION` (`IAsyncOperation<T>`) | 9fc2b0bb-e446-44e2-aa61-9cab8f636af2 | `windows-future` bindings.rs:1399 |
| `PIID_ASYNC_OPERATION_COMPLETED` (`AsyncOperationCompletedHandler<T>`) | fcdcf02c-e5d8-4478-915a-4d90b74b83a5 | `windows-future` bindings.rs:341 |
| `PIID_VECTOR_VIEW` (`IVectorView<T>`) | bbe1fa4c-b0e3-4583-baef-1f1b2e483e56 | `windows-collections` bindings.rs:2591 |
| `PIID_ITERABLE` (`IIterable<T>`) | faa585ea-6214-4217-afda-7f46de5869b3 | `windows-collections` bindings.rs:41 |
| `PIID_REFERENCE` (`IReference<T>`) | 61c17706-2d65-11e0-9ae8-d48564015472 | `windows-0.62.2` `Windows/Foundation/mod.rs` (`IReference<T>` SIGNATURE) — **(one source; confirmed indirectly by the IReference IID vectors below)** |

**Test vectors** (`pinterface_test.c3`, all reproduced by `pinterface::instance`; the expected values are
the MIDL-generated IIDs in **M** `windows.foundation.h`, which the mingw headers take from the Windows SDK):

| Instance | Expected IID | M location | Computed by the C3 code |
| --- | --- | --- | --- |
| `IAsyncOperation<Boolean>` | cdb5efb3-5788-509d-9be1-71ccb8a3362a | `DEFINE_GUID(IID___FIAsyncOperation_1_boolean, ...)` line 11399 | ✓ |
| `IVectorView<HSTRING>` | 2f13c006-a03a-5f69-b090-75a43e33423e | `IID___FIVectorView_1_HSTRING` line 9141 | ✓ |
| `IIterable<HSTRING>` | e2fcc7c1-3bfc-5a0b-b2b0-72e769d1cb7e | `IID___FIIterable_1_HSTRING` line 7876 | ✓ |
| `IAsyncOperation<HSTRING>` | 3e1fe603-f897-5263-b328-0806426b8a79 | `IID___FIAsyncOperation_1_HSTRING` line 11119 | ✓ |
| `AsyncOperationCompletedHandler<Boolean>` | c1d3d1a2-ae17-5a5f-b5a2-bdcc8844889a | `IID___FIAsyncOperationCompletedHandler_1_boolean` line 10659 | ✓ |
| `IReference<Int32>` | 548cefbd-bc8a-5fa0-8df2-957440fc8bf4 | `IID___FIReference_1_INT32` line 12587 | ✓ |
| `IReference<Boolean>` | 3c00fd60-2950-5939-a21a-2d12c5a01b8a | `IID___FIReference_1_boolean` line 13685 | ✓ |

The vectors were also recomputed independently in Python (`hashlib.sha1` over the namespace
bytes and the signature), and agree with both the mingw values and the C3 test.

## 6. Terminal Services sessions (`session.c3`)

* `WTSRegisterSessionNotification(HWND, DWORD)`, `NOTIFY_FOR_THIS_SESSION` = 0,
  `NOTIFY_FOR_ALL_SESSIONS` = 1: **M** `wtsapi32.h`, **W** `wtsapi32.h`; **L** `WTSRegisterSessionNotification` (Library Wtsapi32.lib).
* `WM_WTSSESSION_CHANGE` = 0x02B1; `WTS_CONSOLE_CONNECT` 1, `_CONSOLE_DISCONNECT` 2, `_REMOTE_CONNECT` 3,
  `_REMOTE_DISCONNECT` 4, `WTS_SESSION_LOGON` 5, `_LOGOFF` 6, `_LOCK` 7, `_UNLOCK` 8, `_REMOTE_CONTROL` 9,
  `_CREATE` 0xA, `_TERMINATE` 0xB: **M** `winuser.h` lines 520-530 (the `#define`s), **L** `WM_WTSSESSION_CHANGE`.
* `WTSQuerySessionInformationW`, `WTSFreeMemory`, `WTS_INFO_CLASS` (`WTSSessionInfoEx` = 25):
  **M** `wtsapi32.h` lines 152, 290-326 (`WTSQuerySessionInformationW(HANDLE, DWORD, WTS_INFO_CLASS, LPWSTR*, DWORD*)`).
* `WTSINFOEXW` = `{ DWORD Level; union WTSINFOEX_LEVEL_W Data; }`, and the level-1 struct starts with
  `ULONG SessionId; WTS_CONNECTSTATE_CLASS SessionState; LONG SessionFlags;`. The union contains
  `LARGE_INTEGER`s, so it is 8-byte aligned and starts at **offset 8**; `SessionFlags` is at **offset 16**.
  Sources: **M** `wtsapi32.h` lines 465-522; **L** `WTSINFOEX_LEVEL1_W` (`learn.microsoft.com/en-us/windows/desktop/api/wtsapi32/ns-wtsapi32-wtsinfoex_level1_w`).
  Checked by `$assert(WtsInfoEx::size == 20)` and the struct comment.
* `WTS_SESSIONSTATE_LOCK` = 0 (locked), `WTS_SESSIONSTATE_UNLOCK` = 1 (unlocked), `WTS_SESSIONSTATE_UNKNOWN`
  = 0xFFFFFFFF: **M** `wtsapi32.h` lines 461-463, **W** `wtsapi32.h`, **L** `WTSINFOEX_LEVEL1_W`. Learn adds: on
  Windows 7 and Server 2008 R2 the two flags are reversed (a code defect). The lock check therefore
  requires Windows 8 or later (documented in `session.c3`).

## 7. Message loop (`message_loop*.c3`)

* **Top-level window, not `HWND_MESSAGE`.** A message-only window "does not receive broadcast
  messages" (**L** "Window Features", Message-Only Windows). `WM_DISPLAYCHANGE` "is only sent to
  top-level windows" (**L** `WM_DISPLAYCHANGE`); `WM_SETTINGCHANGE` is "sent to all top-level windows"
  (**L** `WM_SETTINGCHANGE`). The brief named `HWND_MESSAGE`; the implementation deviates on purpose:
  the window is a `WS_POPUP` that is never shown (`WS_EX_TOOLWINDOW`). `HWND_MESSAGE` = `(HWND)-3`
  (**M** and **W** `winuser.h`) is not used.
* Window messages (**M** `winuser.h`, all matching **W** where present): `WM_NCCREATE` 0x0081,
  `WM_SETTINGCHANGE` = `WM_WININICHANGE` 0x001A (**M**; **L** gives the same value), `WM_DEVICECHANGE` 0x0219,
  `WM_POWERBROADCAST` 0x0218, `WM_DPICHANGED` 0x02E0 (also in std), `WM_APP` 0x8000, `WM_DISPLAYCHANGE` 0x007E (also std).
* Parameter layouts used by the event translation: `WM_DPICHANGED` wParam `LOWORD` = X DPI, `HIWORD` = Y DPI
  (**L** `WM_DPICHANGED`); `WM_DISPLAYCHANGE` wParam = bits per pixel, lParam `LOWORD` width, `HIWORD` height
  (**L** `WM_DISPLAYCHANGE`); `WM_WTSSESSION_CHANGE` wParam = the `WTS_SESSION_*` code, lParam = session id
  (**L** `WM_WTSSESSION_CHANGE`); `WM_SETTINGCHANGE` wParam = the SPI action, lParam = the section name or null
  (**L** `WM_SETTINGCHANGE`, the text "sent to all top-level windows").
* Power (`PBT_*`, **M** and **W** `winuser.h`): `PBT_POWERSETTINGCHANGE` 0x8013 (32787), `PBT_APMSUSPEND` 0x0004,
  `PBT_APMRESUMESUSPEND` 0x0007, `PBT_APMRESUMEAUTOMATIC` 0x0012, `PBT_APMPOWERSTATUSCHANGE` 0x000A.
* `POWERBROADCAST_SETTING` = `{ GUID PowerSetting; DWORD DataLength; UCHAR Data[1]; }` (**M** `winuser.h` ~line 1313):
  `Data` at offset 20.
* `RegisterPowerSettingNotification(HANDLE, LPCGUID, DWORD) → HPOWERNOTIFY` and
  `UnregisterPowerSettingNotification` (**M** `winuser.h`; **L** `RegisterPowerSettingNotification`:
  `DEVICE_NOTIFY_WINDOW_HANDLE` = 0 delivers `WM_POWERBROADCAST`/`PBT_POWERSETTINGCHANGE`).
* `RegisterDeviceNotificationW(HANDLE, LPVOID, DWORD)` and `UnregisterDeviceNotification` (**M** `winuser.h`;
  **L** `RegisterDeviceNotificationW`). `DEV_BROADCAST_DEVICEINTERFACE_W` = `{ dbcc_size, dbcc_devicetype,
  dbcc_reserved, GUID dbcc_classguid, WCHAR dbcc_name[1] }` (**M** `dbt.h` lines 178-184; name at offset 28;
  `DBT_DEVTYP_DEVICEINTERFACE` = 5). `DBT_DEVICEARRIVAL` 0x8000, `DBT_DEVICEREMOVECOMPLETE` 0x8004,
  `DBT_DEVNODES_CHANGED` 0x0007 (**M** `dbt.h`; **W** `dbt.h`).
* `CREATESTRUCTW` (**M** `winuser.h` lines 1847-1860; `lpCreateParams` first). `GWLP_USERDATA` = -21 (std and **M**).
* `MsgWaitForMultipleObjectsEx(DWORD, HANDLE*, DWORD, DWORD, DWORD)` (**M** `winuser.h`; **L**);
  `MWMO_INPUTAVAILABLE` = 0x0004 (**M** and **W**); `QS_ALLINPUT` = 0x1CFF, computed from its
  definition in **M** `winuser.h` (`QS_INPUT | QS_POSTMESSAGE | QS_TIMER | QS_PAINT | QS_HOTKEY | QS_SENDMESSAGE`)
  and matching the value `bleu_rt`'s poller uses.
* `DispatchMessageW(const MSG*)` (**M** `winuser.h`). `PeekMessageW`, `TranslateMessage`, `PM_REMOVE`,
  `PostMessageW`, `SetWindowLongPtrW`, `GetWindowLongPtrW`, `CreateWindowExW`, `RegisterClassExW` come from
  the standard library's `std::os::win32` (`winuser.c3`); their signatures were checked against **M**.

### 7a. Application messages, clipboard listener, hot keys (`message_codes.c3`, `message_loop_register.c3`)

* Application range (**L** "WM_APP": "Message numbers in the third range (0x8000 through 0xBFFF) are
  available for applications to use as private messages. Messages in this range do not conflict with system
  messages"). `WM_APP` 0x8000: **M** `winuser.h` line 1438; **R** `windows-sys` 0.59.0
  `Windows/Win32/UI/WindowsAndMessaging/mod.rs` line 2359 (`32768`). `Loop.allocate_message` hands out ids from
  `WM_APP + 2` (`WM_APP + 1` is `WM_WAKE`) through 0xBFFF, per loop, never reused.
* `WM_HOTKEY` 0x0312: **M** `winuser.h` line 1412; **R** `windows-sys` `mod.rs` line 2432 (`786`); **L** "WM_HOTKEY":
  wParam is the hot-key id, lParam's low-order word the modifiers and its high-order word the virtual-key code.
* `WM_CLIPBOARDUPDATE` 0x031D: **M** `winuser.h` line 1417; **R** `windows-sys` `mod.rs` line 2371 (`797`); **L**
  "WM_CLIPBOARDUPDATE": posted "whenever the contents of the clipboard have changed" to a window added with
  `AddClipboardFormatListener`.
* `AddClipboardFormatListener(HWND) -> BOOL` and `RemoveClipboardFormatListener(HWND) -> BOOL`: **M** `winuser.h`
  lines 2499-2500; **W** `winuser.h` lines 3877 and 4550; **R** `windows-sys` `Windows/Win32/System/DataExchange/mod.rs`
  lines 3 and 76 (`user32.dll`); **L** "AddClipboardFormatListener" ("Windows Vista [desktop apps only]").
  Not bound by the shipped `std::os::win32` (`/opt/c3/c3/lib/std/os/win32`, searched), so declared in `message_loop_register.c3`.
* `RegisterHotKey(HWND, int, UINT, UINT) -> BOOL` and `UnregisterHotKey(HWND, int) -> BOOL`: **M** `winuser.h` lines
  1988-1989; **W** `winuser.h` lines 4535 and 4719; **R** `windows-sys` `Input/KeyboardAndMouse/mod.rs` lines 30 and 45
  (`id: i32`); **L** "RegisterHotKey", "UnregisterHotKey". Learn: the id must be in 0x0000 through 0xBFFF (shared DLLs use
  0xC000 and up). With the same window and id, a second registration "is maintained along with the new hot key" (Windows
  Server 2003 replaced it), and "The application must explicitly call UnregisterHotKey to unregister the old hot key". So
  the loop keeps the ids it registered (`List{uint}` in `Loop`), refuses a reused id with `INVALID_STATE` before any
  Win32 call, and `close` calls `UnregisterHotKey` for each one it still holds. Both functions return zero on failure;
  `GetLastError` gives the code, which `errors::raise_win32` / `raise_last` record.
* `MOD_ALT` 0x0001, `MOD_CONTROL` 0x0002, `MOD_SHIFT` 0x0004, `MOD_WIN` 0x0008, `MOD_NOREPEAT` 0x4000: **M** `winuser.h`
  lines 1992-1997; **R** `windows-sys` lines 151-155; **L** "RegisterHotKey" (the `fsModifiers` table).
* `LOWORD` and `HIWORD` (`message_codes.c3`, `low_word`/`high_word`): **M** `minwindef.h` lines 184-185; **W**
  `minwindef.h` lines 306-307.
* Decoding is covered by `message_codes_test.c3`: a `WM_HOTKEY` lParam of `0x00410006` gives modifiers 0x0006 and
  virtual-key 0x41, and bits above 32 of a 64-bit LPARAM are ignored. The allocator test covers the first id (0x8002),
  the owned set, and `CAPACITY_EXCEEDED` after 0xBFFF.
* Dispatch (`message_loop.c3`): `WM_HOTKEY` becomes `HOTKEY`, `WM_CLIPBOARDUPDATE` becomes `CLIPBOARD_UPDATED`, and a
  message in the application range this loop allocated becomes `CUSTOM_MESSAGE` (wParam and lParam as posted). Any other
  message in the range is not reported, as before.

## 8. Registry (`registry*.c3`)

* `KEY_QUERY_VALUE` 0x1, `KEY_SET_VALUE` 0x2, `KEY_CREATE_SUB_KEY` 0x4, `KEY_ENUMERATE_SUB_KEYS` 0x8,
  `KEY_NOTIFY` 0x10, `KEY_WOW64_64KEY` 0x100, `KEY_WOW64_32KEY` 0x200 (**M** and **W** `winnt.h`; **L**
  "Accessing an Alternate Registry View").
* `KEY_READ` = 0x20019 and `KEY_WRITE` = 0x20006: **M** `winnt.h` line 9986-9987 defines them from
  `STANDARD_RIGHTS_*` (READ_CONTROL 0x20000) and the flags above (SYNCHRONIZE removed).
* `REG_NONE` 0, `REG_SZ` 1, `REG_EXPAND_SZ` 2, `REG_BINARY` 3, `REG_DWORD` 4, `REG_MULTI_SZ` 7, `REG_QWORD` 11
  (**M** and **W** `winnt.h`).
* `REG_NOTIFY_CHANGE_NAME` 1, `_ATTRIBUTES` 2, `_LAST_SET` 4 (**M** and **W** `winnt.h`; **L** `RegNotifyChangeKeyValue`).
* `RegOpenKeyExW(HKEY, LPCWSTR, DWORD, REGSAM, PHKEY)`, `RegQueryValueExW(HKEY, LPCWSTR, LPDWORD, LPDWORD, LPBYTE, LPDWORD)`,
  `RegSetValueExW(HKEY, LPCWSTR, DWORD, DWORD, const BYTE*, DWORD)`, `RegEnumKeyExW`, `RegEnumValueW`,
  `RegNotifyChangeKeyValue(HKEY, BOOL, DWORD, HANDLE, BOOL)`, `RegCloseKey` (**M** `winreg.h` lines 403-424).
* `CreateEventW(LPSECURITY_ATTRIBUTES, BOOL, BOOL, LPCWSTR)` (**M** `synchapi.h`).
* Size limits: key name 255 characters, value name 16,383 characters (**L** "Registry Element Size Limits").
* Error codes: `RegOpenKeyExW` and the other `Reg*` calls return the error code directly (not via
  `GetLastError`); the library passes it to `errors::raise_win32`.
* `HKEY_LOCAL_MACHINE`, `HKEY_CURRENT_USER`: the standard library's constants (`winreg.c3`), checked
  against **M** `winreg.h`.

## 9. Process helpers (`process.c3`)

* `TOKEN_INFORMATION_CLASS`: `TokenUser` = 1, `TokenElevation` = 20 (counted in **M** `winnt.h` lines 4122-4146;
  **L** `TOKEN_INFORMATION_CLASS` lists the same order).
* `TOKEN_ELEVATION` = `{ DWORD TokenIsElevated; }` (**M** `winnt.h` line 4251).
* `TOKEN_USER` = `{ SID_AND_ATTRIBUTES User; }`, `SID_AND_ATTRIBUTES` = `{ PSID Sid; DWORD Attributes; }`
  (**M** `winnt.h` lines 3223 and 4175); 16 bytes on 64-bit Windows.
* `OpenProcessToken(HANDLE, DWORD, PHANDLE)`, `GetTokenInformation(HANDLE, TOKEN_INFORMATION_CLASS, LPVOID, DWORD, PDWORD)`
  (**M** `securitybaseapi.h`); `TOKEN_QUERY` 0x0008 (**M** `winnt.h`).
* `ConvertSidToStringSidW(PSID, LPWSTR*)` (**M** `sddl.h`; `windows` crate: `advapi32.dll`) and `LocalFree` (**M** `winbase.h`).
* `OpenProcess(DWORD, BOOL, DWORD)`, `QueryFullProcessImageNameW(HANDLE, DWORD, LPWSTR, PDWORD)` (**M** `processthreadsapi.h`;
  `windows` crate: `kernel32.dll`), `PROCESS_QUERY_LIMITED_INFORMATION` = 0x1000 (**M** `winnt.h`).
* `ProcessIdToSessionId(DWORD, PDWORD)` (**M** `processthreadsapi.h`; `windows` crate: `kernel32.dll`).
* Path length: 32,767 characters (**L** "Maximum file path limitation").

## 10. Text, HSTRING, BSTR

* UTF-8 ⇄ UTF-16: the standard library's `String.to_utf16`, `string::from_wstring`, `string::from_utf16`
  (**S** `core/string.c3` lines 896-1222), which validate both directions. `MultiByteToWideChar` is not used.
  The test `wide_round_trip_keeps_text` checks the surrogate pair of U+1D11E.
* `SysAllocStringLen(const OLECHAR*, UINT)`, `SysFreeString(BSTR)`, `SysStringLen(BSTR)` (**M** `oleauto.h`;
  `windows` crate: `oleaut32.dll`).

## 11. Power setting GUIDs (values)

| Name | Value | Sources |
| --- | --- | --- |
| `GUID_CONSOLE_DISPLAY_STATE` | 6fe69556-704a-47a0-8f24-c28d936fda47 | **M** `winnt.h` line 6605; **L** "Power setting GUIDs" |
| `GUID_ACDC_POWER_SOURCE` | 5d3e9a59-e9d5-4b00-a6bd-ff34ff516548 | **M** line 6693; **L** |
| `GUID_BATTERY_PERCENTAGE_REMAINING` | a7ad8041-b45a-4cae-87a3-eecbb468a9e1 | **M** line 6695; **L** |
| `GUID_SESSION_DISPLAY_STATUS` | 2b84c20e-ad23-4ddf-93db-05ffbd7efca5 | **M** line 6697; **L** |
| `GUID_SESSION_USER_PRESENCE` | 3c0f4548-c03f-4c4d-b9f2-237ede686376 | **M** line 6698; **L** |

Data values from **L**: ACDC 0 AC, 1 DC (battery), 2 UPS; battery 0-100 percent; console and session display
`MONITOR_DISPLAY_STATE` 0 off, 1 on, 2 dimmed.

## 12. Layout checks

Compile-time: `$assert(Guid::size == 16)` (`guid.c3`), `$assert(WtsInfoEx::size == 20)` (`session.c3`).
Field offsets that rely on C's natural alignment, not on a check: `DeviceInterfaceBroadcast.name` (28),
`PowerBroadcastSetting.data` (20), `WtsInfoEx.session_flags` (16). These follow from the C struct
declarations cited above, and C3 uses the C layout for structs without `@packed`.

## 13. Not verified, and open risks

1. **Nothing ran on Windows.** Every Windows function is compile-checked only. The behaviour
   claims (broadcast delivery to the hidden window, `WTS` lock state, `RegNotifyChangeKeyValue` one-shot
   semantics, `CoInitializeEx` balancing) rest on Learn and the headers, not on an experiment.
2. **Import library names** (`ole32`, `combase`/`runtimeobject`, `oleaut32`, `advapi32`, `user32`,
   `wtsapi32`, `kernel32`) come from the `windows` crate's link attributes and Learn's "Library" lines.
   A Windows link has not been attempted; `RoInitialize` and the string functions use `runtimeobject`
   (Learn) and the crate's API-set names.
3. The `Win32_MSG`, `Win32_WNDCLASSEXW`, `Win32_POINT`, `Win32_RECT`, `WNDPROC` and the `PeekMessageW`
   family are the standard library's declarations; their layouts were not re-derived here.
4. `CoCreateInstance` is used (desktop). Store/UWP code would need `CoCreateInstanceFromApp`
   (**M** `combaseapi.h` lines 241-273).
5. The `IReference` PIID (61c17706-...) is taken from the `windows` crate; its IIDs match the mingw
   values, which confirms it indirectly.
6. `RegQueryValueExW` returns the size on the first call; a value that grows between calls is retried
   up to `READ_ATTEMPTS` times.
7. `Hstring.close` and `Bstr.close` free with the matching APIs; `WideZ.free` frees the allocator's
   buffer. None of these were exercised.
8. The clipboard listener, the hot keys and the application messages are compiled only. Nothing shows that a
   hidden top-level window receives `WM_CLIPBOARDUPDATE` or `WM_HOTKEY` through this loop, or that a hot key
   registered on it fires.
9. `Loop.close` removes the clipboard listener itself when `add_clipboard_listener` succeeded. The Learn pages read
   do not say whether destroying a window leaves the listener chain by itself, so the explicit removal is the safe path.
