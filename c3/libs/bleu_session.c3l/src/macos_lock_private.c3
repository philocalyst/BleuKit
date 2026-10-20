<*
 PRIVATE API. The macOS lock request is `SACLockScreenImmediate` in login.framework, a private
 framework. It is resolved at run time with `bleu::dl`, and only when `Options.allow_private`
 is set: the public API has no lock request. A missing or renamed symbol leaves the lock
 capability UNSUPPORTED_BACKEND; it never stops the library from loading.

 Symbol and framework: `void SACLockScreenImmediate(void)` in
 /System/Library/PrivateFrameworks/login.framework/login, as used by open-source lock tools.
 UNVERIFIED here: the research record (docs/research/session_windows_input.md, section 2,
 macOS) marks it so, and no header or primary source for it was read.

 Observed on: NOT RUN. Compiled for macos-aarch64 and macos-x64 only.
*>
module bleu::session::macos_lock @feat(DARWIN);
import bleu::dl, bleu::error;

const String LOGIN_FRAMEWORK = "/System/Library/PrivateFrameworks/login.framework/login";

alias LockScreenFn = fn void();

<* The one function this file uses from login.framework. *>
struct LockScreenApi
{
	LockScreenFn lock_screen_immediate @tag("sym", "SACLockScreenImmediate");
}

<* The framework and the function bound from it. The library stays loaded for the life of the process. *>
struct LockScreen
{
	dl::Library library;
	LockScreenApi api;
}

<*
 Open login.framework and bind `SACLockScreenImmediate`.

 @return? error::UNSUPPORTED : "The framework or the symbol is not present"
*>
fn void? open_lock_screen(LockScreen* lock)
{
	String[1] candidates = { LOGIN_FRAMEWORK };
	lock.library = dl::open(candidates[..])!;
	dl::bind(&lock.api, &lock.library)!;
}