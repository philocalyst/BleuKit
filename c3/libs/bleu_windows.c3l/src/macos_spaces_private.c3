<*
 PRIVATE API. Mission Control Spaces, read through the SkyLight private framework.
 Resolved at run time with `bleu::dl`, and only when `Options.allow_private` is set.
 A missing or renamed symbol leaves the Spaces capabilities unsupported; it never
 stops the library from loading.

 What is used, and where it was seen:
 - `SLSMainConnectionID(void) -> int`: the connection to the window server.
 Hammerspoon extensions/spaces/libspaces.m:281 (`g_connection = SLSMainConnectionID()`);
 yabai src/misc/extern.h:9 (`extern int SLSMainConnectionID(void);`). Two sources.
 - `SLSGetActiveSpace(int connection) -> space id`: the Space on the focused screen.
 Hammerspoon libspaces.m:84 calls it and pushes the result as an integer. The header
 that declares the return type was not read, so the 64-bit unsigned return is
 UNVERIFIED (one source: the call site). The Space id is written as text.
 - Not used: `SLSCopyManagedDisplaySpaces` (yabai extern.h:60 declares it). Its dictionary
 shape is not verified (Hammerspoon calls it an "entirely too complex" table, libspaces.m:27-36
 comment), so the list of Spaces is not read.
 - Not used: moving windows between Spaces (SLSMoveWindowsToManagedSpace, and the
 scripting addition that needs SIP partly disabled: yabai README).

 Framework path: /System/Library/PrivateFrameworks/SkyLight.framework/SkyLight.
 Observed on: NOT RUN. Compiled for macos-aarch64 and macos-x64 only.
*>
module bleu::windows::macos_spaces_private @feat(DARWIN);
import bleu::dl, bleu::error;

const String SKYLIGHT_PATH = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight";

alias MainConnectionFn = fn int();
alias ActiveSpaceFn = fn ulong(int connection);

<* The two SkyLight functions this file uses. Each symbol must resolve or the table does not bind. *>
struct SkyLightApi
{
	MainConnectionFn main_connection_id @tag("sym", "SLSMainConnectionID");
	ActiveSpaceFn active_space @tag("sym", "SLSGetActiveSpace");
}

<* SkyLight and the functions bound from it. The library stays loaded for the life of the service. *>
struct SkyLight
{
	dl::Library library;
	SkyLightApi api;
}

<*
 Open SkyLight and bind the two functions.

 @return? error::UNSUPPORTED : "SkyLight or one of its symbols is not present"
*>
fn void? open_skylight(SkyLight* spaces)
{
	String[1] candidates = { SKYLIGHT_PATH };
	spaces.library = dl::open(candidates[..])!;
	dl::bind(&spaces.api, &spaces.library)!;
}

<* Close SkyLight. Nothing bound from it may be called afterwards. *>
fn void SkyLight.close(&self) => self.library.close();

<*
 The Space shown on the focused screen.

 @return? error::BACKEND_FAILURE : "The window server did not give a connection"
*>
fn ulong? active_space(SkyLight* spaces)
{
	int connection = spaces.api.main_connection_id();
	if (connection == 0) return error::raise(
		error::BACKEND_FAILURE,
		error::Domain.INTERNAL,
		0,
		"SLSMainConnectionID returned 0"
	)~;
	return spaces.api.active_space(connection);
}