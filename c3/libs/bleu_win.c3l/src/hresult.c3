<*
 HRESULT and Win32 error codes, and their mapping onto the Bleu error
 vocabulary (`bleu::error`).

 Two code spaces meet here. An HRESULT is 32 bits: a severity bit, a 11-bit
 facility and a 16-bit code. The facility `FACILITY_WIN32` (7) carries a
 Win32 error code in its low 16 bits (`HRESULT_FROM_WIN32`), so every Win32
 error reaches the caller as an HRESULT and is mapped once, by code, in
 `win32_to_fault`. Other HRESULTs are mapped by value in `Hresult.to_fault`.

 Every value below is cross-checked against mingw-w64 `winerror.h` and Wine
 `include/winerror.h` (docs/research/bleu_win.md, section 2).

 Pure logic: no Win32 import, unit-tested on every host.
*>
module bleu::win::hresult;
import bleu::error;

<* A 32-bit HRESULT (`typedef LONG HRESULT`). Negative values are failures. *>
typedef Hresult = int;

<* `FACILITY_WIN32`: the HRESULT facility that carries a Win32 error code (winerror.h). *>
const uint FACILITY_WIN32 = 7;

<* Success. *>
const uint S_OK               = 0x00000000;
<* Success with a non-default meaning, e.g. `CoInitializeEx` on an already-initialised thread. *>
const uint S_FALSE            = 0x00000001;
<* The object does not implement the requested interface. *>
const uint E_NOINTERFACE      = 0x80004002;
<* Not implemented. *>
const uint E_NOTIMPL          = 0x80004001;
<* Unspecified failure. *>
const uint E_FAIL             = 0x80004005;
<* Null pointer argument. *>
const uint E_POINTER          = 0x80004003;
<* `HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED)`. *>
const uint E_ACCESSDENIED     = 0x80070005;
<* `HRESULT_FROM_WIN32(ERROR_OUTOFMEMORY)`. *>
const uint E_OUTOFMEMORY      = 0x8007000E;
<* `HRESULT_FROM_WIN32(ERROR_INVALID_PARAMETER)`. *>
const uint E_INVALIDARG       = 0x80070057;
<* The COM apartment model of this thread conflicts with an earlier initialisation. *>
const uint RPC_E_CHANGED_MODE = 0x80010106;
<* The COM server went away (RPC facility). *>
const uint RPC_E_DISCONNECTED = 0x80010108;

<* System error codes (Win32 `GetLastError` values), from winerror.h. *>
const uint ERROR_FILE_NOT_FOUND            = 2;
const uint ERROR_PATH_NOT_FOUND            = 3;
const uint ERROR_ACCESS_DENIED             = 5;
const uint ERROR_INVALID_HANDLE            = 6;
const uint ERROR_NOT_ENOUGH_MEMORY         = 8;
const uint ERROR_INVALID_FUNCTION          = 1;
const uint ERROR_NOT_SUPPORTED             = 50;
const uint ERROR_INVALID_PARAMETER         = 87;
const uint ERROR_INSUFFICIENT_BUFFER       = 122;
const uint ERROR_BUSY                      = 170;
const uint ERROR_ALREADY_EXISTS            = 183;
const uint ERROR_OUTOFMEMORY               = 14;
const uint ERROR_MORE_DATA                 = 234;
const uint ERROR_NO_MORE_ITEMS             = 259;
const uint ERROR_CANCELLED                 = 1223;
const uint ERROR_TIMEOUT                   = 1460;
const uint ERROR_NOT_FOUND                 = 1168;
const uint ERROR_NONE_MAPPED               = 1332;
<* `ERROR_HOTKEY_ALREADY_REGISTERED`: another registration holds this key combination (winerror.h). *>
const uint ERROR_HOTKEY_ALREADY_REGISTERED = 1409;
<* `ERROR_HOTKEY_NOT_REGISTERED`: `UnregisterHotKey` was given an id that is not registered (winerror.h). *>
const uint ERROR_HOTKEY_NOT_REGISTERED     = 1419;
const uint WAIT_TIMEOUT                    = 258;
<* RPC server unavailable (`RPC_S_SERVER_UNAVAILABLE`), a Win32 code. *>
const uint RPC_S_SERVER_UNAVAILABLE        = 1722;

<* True when the severity bit is set. Same as the `FAILED` macro. *>
fn bool Hresult.failed(self) @inline => (int)self < 0;

<* True when the severity bit is clear. Same as the `SUCCEEDED` macro. *>
fn bool Hresult.succeeded(self) @inline => (int)self >= 0;

<*
 `HRESULT_FROM_WIN32(code)`: wrap a Win32 error code as an HRESULT. Values
 that are not positive are passed through unchanged, as the macro does.

 @param code : "A Win32 error code, as `GetLastError` returns it"
*>
fn Hresult from_win32(uint code) @inline
{
	if ((int)code <= 0) return (Hresult)code;
	return (Hresult)((code & 0x0000ffff) | (FACILITY_WIN32 << 16) | 0x80000000);
}

<* True when this HRESULT carries a Win32 error code in its low 16 bits. *>
fn bool Hresult.is_win32(self) @inline
{
	return self.failed() && (((uint)self >> 16) & 0x1fff) == FACILITY_WIN32;
}

<*
 Map a failed HRESULT onto the fault a refused operation should raise.
 Win32-facility codes go through `win32_to_fault`; the rest are matched by value.
 Anything unrecognised is `BACKEND_FAILURE`.

 @require self.failed() : "Only failures have a fault"
*>
fn fault Hresult.to_fault(self)
{
	if (self.is_win32()) return win32_to_fault((uint)self & 0x0000ffff);
	switch ((uint)self)
	{
		case E_NOTIMPL: return error::UNSUPPORTED;
		case RPC_E_DISCONNECTED: return error::DISCONNECTED;
		default: return error::BACKEND_FAILURE;
	}
}

<*
 Map a Win32 error code onto the Bleu vocabulary. `ERROR_FILE_NOT_FOUND`,
 `ERROR_PATH_NOT_FOUND`, `ERROR_NOT_FOUND` and `ERROR_HOTKEY_NOT_REGISTERED` are
 "not found"; `ERROR_TIMEOUT` and `WAIT_TIMEOUT` are timeouts;
 `ERROR_HOTKEY_ALREADY_REGISTERED` is `BUSY` (another program holds the chord);
 `RPC_S_SERVER_UNAVAILABLE` means the peer is gone. The rest of the table is in the
 body; everything else is `BACKEND_FAILURE`.

 @param code : "A Win32 error code (not an HRESULT)"
*>
fn fault win32_to_fault(uint code)
{
	switch (code)
	{
		case ERROR_FILE_NOT_FOUND:
		case ERROR_PATH_NOT_FOUND:
		case ERROR_NOT_FOUND:
		case ERROR_HOTKEY_NOT_REGISTERED: return NOT_FOUND;
		case ERROR_ACCESS_DENIED: return error::PERMISSION_DENIED;
		case ERROR_NOT_ENOUGH_MEMORY:
		case ERROR_OUTOFMEMORY: return error::NO_MEMORY;
		case ERROR_INVALID_PARAMETER: return error::INVALID_ARGUMENT;
		case ERROR_NOT_SUPPORTED: return error::UNSUPPORTED;
		case ERROR_TIMEOUT:
		case WAIT_TIMEOUT: return TIMEOUT;
		case ERROR_BUSY:
		case ERROR_HOTKEY_ALREADY_REGISTERED: return error::BUSY;
		case ERROR_CANCELLED: return error::CANCELLED;
		case RPC_S_SERVER_UNAVAILABLE: return error::DISCONNECTED;
		default: return error::BACKEND_FAILURE;
	}
}