<*
 The CoreGraphics window list and the screen-capture permission check.

 Constants and signatures: CGWindow.h and CGRect.h through the objc2-core-graphics
 0.3.1 crate in the research scratchpad (`generated/CGWindow.rs`, lines 65-146: the
 key names and `OptionOnScreenOnly = 1<<0`, `ExcludeDesktopElements = 1<<4`);
 `CGPreflightScreenCaptureAccess` in x-win 5.0.0 `src/macos/permission.rs` (two uses).
 `CGWindowListCopyWindowInfo` and `CGRectMakeWithDictionaryRepresentation` signatures:
 Apple reference pages, read in the research record (AJ-cgwindowlistcopywindowinfo).
 `CGRectMakeWithDictionaryRepresentation` is single-source here (its signature is not in
 the crates read).
*>
module bleu::windows::macos_cg @feat(DARWIN) @link("CoreGraphics.framework");
import bleu::cf;

// kCGWindowListOptionOnScreenOnly: only windows on screen (not minimized, not on other Spaces).
const uint OPTION_ON_SCREEN_ONLY           = 1;
// kCGWindowListExcludeDesktopElements: the desktop and the dock's own windows are left out.
const uint OPTION_EXCLUDE_DESKTOP_ELEMENTS = 16;
// kCGNullWindowID (CGWindow.h; objc2-core-graphics CGWindow.rs:11 = 0): relative to no window.
const uint NULL_WINDOW_ID                  = 0;

// CGRect as the window dictionary's bounds describe it: origin and size, all CGFloat (double).
struct CgRect
{
	double x;
	double y;
	double width;
	double height;
}

extern fn cf::CFTypeRef cg_window_list_copy_window_info(
	uint options,
	uint relative_to
) @cname("CGWindowListCopyWindowInfo");
extern fn bool cg_preflight_screen_capture_access() @cname("CGPreflightScreenCaptureAccess");
extern fn bool cg_rect_make_with_dictionary_representation(
	cf::CFTypeRef dictionary,
	CgRect* rect
) @cname("CGRectMakeWithDictionaryRepresentation");
extern fn cf::CFTypeRef cf_dictionary_get_value(
	cf::CFTypeRef dictionary,
	cf::CFTypeRef key
) @cname("CFDictionaryGetValue");

extern const cf::CFTypeRef KCG_WINDOW_NUMBER @cname("kCGWindowNumber");
extern const cf::CFTypeRef KCG_WINDOW_OWNER_PID @cname("kCGWindowOwnerPID");
extern const cf::CFTypeRef KCG_WINDOW_OWNER_NAME @cname("kCGWindowOwnerName");
extern const cf::CFTypeRef KCG_WINDOW_NAME @cname("kCGWindowName");
extern const cf::CFTypeRef KCG_WINDOW_LAYER @cname("kCGWindowLayer");
extern const cf::CFTypeRef KCG_WINDOW_BOUNDS @cname("kCGWindowBounds");

<*
 The on-screen windows, front to back, as a CFArray the caller owns.

 @return "A retained CFArray of CFDictionary records; null when the window server gave none"
*>
fn cf::Ref window_list()
{
	return cf::adopt(
		cg_window_list_copy_window_info(OPTION_ON_SCREEN_ONLY | OPTION_EXCLUDE_DESKTOP_ELEMENTS, NULL_WINDOW_ID)
	);
}

<* The value of `key` in a window record, borrowed; null when the record has none. *>
fn cf::CFTypeRef record_value(cf::CFTypeRef record, cf::CFTypeRef key)
{
	if (record == null) return null;
	return cf_dictionary_get_value(record, key);
}

<* The bounds of a window record. False when the record has no bounds. *>
fn bool record_bounds(cf::CFTypeRef record, CgRect* bounds)
{
	cf::CFTypeRef dictionary = record_value(record, KCG_WINDOW_BOUNDS);
	if (dictionary == null) return false;
	return cg_rect_make_with_dictionary_representation(dictionary, bounds);
}

<*
 Whether the process may read other applications' window titles (Screen Recording).
 Without it the window server withholds the titles, and nothing else is affected.
*>
fn bool screen_capture_allowed() => cg_preflight_screen_capture_access();