<*
 The CoreGraphics functions the display backend calls, bound directly. Every signature and value
 here is cross-checked against the generated bindings of objc2-core-graphics 0.3.1 (src/generated/
 CGDirectDisplay.rs and CGDisplayConfiguration.rs), which are generated from the Apple SDK headers,
 and against core-graphics 0.24.0 (src/display.rs). The standard library binds only the mode calls.

 Configuration option values (CGConfigureOption): ForAppOnly 0, ForSession 1, Permanently 2.
 CGError: kCGErrorSuccess is 0.
*>
module bleu::display::macos_native @feat(DARWIN) @link("CoreGraphics.framework");
import bleu::cf;

<* A display number, CGDirectDisplayID. *>
alias DirectDisplayId = uint;

<* An opaque CGDisplayConfigRef, a pending transaction. *>
alias ConfigRef = void*;

<* A CGError code: 0 is success. *>
alias CgError = int;

const CgError CG_SUCCESS = 0;

// CGConfigureOption values: the scope a transaction is completed with.
const uint CONFIGURE_FOR_SESSION = 1;
const uint CONFIGURE_PERMANENTLY = 2;

<* CGPoint and CGSize, as doubles (CGFloat is double on 64-bit targets). *>
struct CgPoint
{
	double x;
	double y;
}

struct CgSize
{
	double width;
	double height;
}

struct CgRect
{
	CgPoint origin;
	CgSize size;
}

<* A reconfiguration callback: the display, the change flags (CGDisplayChangeSummaryFlags), the user pointer. *>
alias ReconfigurationFn = fn void(DirectDisplayId display, uint flags, void* user);

// CGDisplayChangeSummaryFlags bit that marks the start of a reconfiguration; the end carries no such bit.
const uint CG_BEGIN_CONFIGURATION_FLAG = 1 << 0;

// CFDictionary callback tables, passed by address to CFDictionaryCreate (CFDictionary.h).
struct CfKeyCallbacks
{
	sz version;
	void* retain;
	void* release;
	void* copy_description;
	void* equal;
	void* hash;
}

struct CfValueCallbacks
{
	sz version;
	void* retain;
	void* release;
	void* copy_description;
	void* equal;
}

extern const CfKeyCallbacks KCF_TYPE_DICTIONARY_KEY_CALLBACKS @cname("kCFTypeDictionaryKeyCallBacks");
extern const CfValueCallbacks KCF_TYPE_DICTIONARY_VALUE_CALLBACKS @cname("kCFTypeDictionaryValueCallBacks");
extern const void* KCG_SHOW_DUPLICATE_LOW_RES_MODES @cname("kCGDisplayShowDuplicateLowResolutionModes");

extern fn DirectDisplayId cg_main_display() @cname("CGMainDisplayID");
extern fn CgError cg_active_displays(uint max, DirectDisplayId* displays, uint* count) @cname("CGGetActiveDisplayList");
extern fn CgRect cg_display_bounds(DirectDisplayId display) @cname("CGDisplayBounds");
extern fn double cg_display_rotation(DirectDisplayId display) @cname("CGDisplayRotation");
extern fn CgSize cg_display_screen_size(DirectDisplayId display) @cname("CGDisplayScreenSize");
extern fn DirectDisplayId cg_display_mirrors(DirectDisplayId display) @cname("CGDisplayMirrorsDisplay");
extern fn void* cg_display_copy_mode(DirectDisplayId display) @cname("CGDisplayCopyDisplayMode");
extern fn void* cg_display_copy_all_modes(
	DirectDisplayId display,
	void* options
) @cname("CGDisplayCopyAllDisplayModes");
extern fn usz cg_mode_width(void* mode) @cname("CGDisplayModeGetWidth");
extern fn usz cg_mode_height(void* mode) @cname("CGDisplayModeGetHeight");
extern fn usz cg_mode_pixel_width(void* mode) @cname("CGDisplayModeGetPixelWidth");
extern fn usz cg_mode_pixel_height(void* mode) @cname("CGDisplayModeGetPixelHeight");
extern fn double cg_mode_refresh_rate(void* mode) @cname("CGDisplayModeGetRefreshRate");
extern fn CgError cg_begin_configuration(ConfigRef* config) @cname("CGBeginDisplayConfiguration");
extern fn CgError cg_configure_origin(
	ConfigRef config,
	DirectDisplayId display,
	int x,
	int y
) @cname("CGConfigureDisplayOrigin");
extern fn CgError cg_configure_mode(
	ConfigRef config,
	DirectDisplayId display,
	void* mode,
	void* options
) @cname("CGConfigureDisplayWithDisplayMode");
extern fn CgError cg_complete_configuration(ConfigRef config, uint option) @cname("CGCompleteDisplayConfiguration");
extern fn CgError cg_cancel_configuration(ConfigRef config) @cname("CGCancelDisplayConfiguration");
extern fn CgError cg_register_reconfiguration(
	ReconfigurationFn callback,
	void* user
) @cname("CGDisplayRegisterReconfigurationCallback");
extern fn CgError cg_remove_reconfiguration(
	ReconfigurationFn callback,
	void* user
) @cname("CGDisplayRemoveReconfigurationCallback");
extern fn void* cf_dictionary_create(
	void* allocator,
	void** keys,
	void** values,
	sz count,
	CfKeyCallbacks* key_callbacks,
	CfValueCallbacks* value_callbacks
) @cname("CFDictionaryCreate");
extern fn sz cf_array_count(void* array) @cname("CFArrayGetCount");
extern fn void* cf_array_value_at(void* array, sz index) @cname("CFArrayGetValueAtIndex");
extern fn void cf_release(void* object) @cname("CFRelease");

<*
 The options that ask CoreGraphics for every mode, including the low-resolution duplicates that
 HiDPI panels list. The dictionary is retained by the caller, who releases it.
*>
fn void* duplicate_mode_options()
{
	void*[1] keys   = { (void*)KCG_SHOW_DUPLICATE_LOW_RES_MODES };
	void*[1] values = { (void*)cf::KCF_BOOLEAN_TRUE };
	return cf_dictionary_create(
		null,
		&keys[0],
		&values[0],
		1,
		&KCF_TYPE_DICTIONARY_KEY_CALLBACKS,
		&KCF_TYPE_DICTIONARY_VALUE_CALLBACKS
	);
}