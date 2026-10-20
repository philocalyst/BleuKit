<*
 Keychain status codes (OSStatus) and their meaning for the library. Pure, so it
 is tested on every platform; the macOS backend calls it.

 Sources, each value cross-checked where two are given:
 * errSecParam -50, errSecAuthFailed -25293, errSecDuplicateItem -25299,
   errSecItemNotFound -25300: security-framework-sys-2.14.0 src/base.rs lines
   50-55 (https://static.crates.io/crates/security-framework-sys/security-framework-sys-2.14.0.crate);
   -25300 also keyring-3.6.2 src/macos.rs line 263 (`NoEntry`).
 * errSecNotAvailable -25291: keyring-3.6.2 src/macos.rs line 259
   (`NoStorageAccess`), the same value as in its ios.rs line 185.
 * errSecUserCanceled -128: security-framework-3.0.1 examples/find_internet_password.rs
   line 28 (`err.code() == -128`, the user cancelled a keychain prompt).
 Not mapped: errSecInteractionNotAllowed (-25308) appears in none of the sources
 read, so it stays BACKEND_FAILURE with its number recorded.
*>
module bleu::secrets::keychain;
import bleu::error;

<* OSStatus of success. *>
const int ERR_SEC_SUCCESS = 0;
<* A parameter was wrong (base.rs). *>
const int ERR_SEC_PARAM = -50;
<* The service is not available (macos.rs 259). *>
const int ERR_SEC_NOT_AVAILABLE = -25291;
<* The user's password was wrong (base.rs). *>
const int ERR_SEC_AUTH_FAILED = -25293;
<* An item with these attributes exists (base.rs). *>
const int ERR_SEC_DUPLICATE_ITEM = -25299;
<* No item matches (base.rs). *>
const int ERR_SEC_ITEM_NOT_FOUND = -25300;
<* The user cancelled a prompt (security-framework example). *>
const int ERR_SEC_USER_CANCELED = -128;

<*
 The excuse a failing keychain call stands for. Duplicate items and missing items
 are handled by the callers before they reach here, so they map to
 INVALID_STATE and NOT_FOUND.
*>
fn fault status_fault(int status)
{
	switch (status)
	{
		case ERR_SEC_PARAM: return error::INVALID_ARGUMENT;
		case ERR_SEC_NOT_AVAILABLE: return error::UNAVAILABLE;
		case ERR_SEC_AUTH_FAILED: return error::AUTH_REQUIRED;
		case ERR_SEC_USER_CANCELED: return error::AUTH_REQUIRED;
		case ERR_SEC_DUPLICATE_ITEM: return error::INVALID_STATE;
		case ERR_SEC_ITEM_NOT_FOUND: return NOT_FOUND;
		default: return error::BACKEND_FAILURE;
	}
}
