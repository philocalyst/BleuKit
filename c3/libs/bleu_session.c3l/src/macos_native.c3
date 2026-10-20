<*
 The CoreGraphics reads of the macOS backend: the HID idle time and the window server's
 session dictionary, which says whether the screen is locked.

 Sources:
 * CGEventSourceSecondsSinceLastEventType(CGEventSourceStateID, CGEventType) -> CFTimeInterval.
 Apple developer documentation (tutorials data, `coregraphics/cgeventsource`, read in
 docs/research/session_windows_input.md, AJ-cgeventsource).
 * kCGEventSourceStateHIDSystemState = 1 and kCGAnyInputEventType = (CGEventType)~0.
 Cross-checked: the Rust crate core-graphics 0.24.0 (`src/event_source.rs`, HIDSystemState = 1)
 and objc2-core-graphics 0.3.1 (generated from the SDK headers: `CGEventTypes.rs`, and the
 translation config, which says kCGAnyInputEventType "needs to be wrapped as CGEventType(!0)").
 * CGSessionCopyCurrentDictionary() -> CFDictionaryRef, a copy the caller releases. Apple
 documentation (AJ-cgsessioncopycurrentdictionary); the declaration is generated in
 objc2-core-graphics 0.3.1 `src/generated/CGSession.rs`.
 * The key CGSSessionScreenIsLocked: UNVERIFIED. Not in any header or crate read here. It is
 the key that common open-source tooling reads; it must be checked on macOS hardware.
*>
module bleu::session::macos_native @feat(DARWIN) @link("CoreGraphics.framework");
import std::collections::maybe, bleu::cf;

// kCGEventSourceStateHIDSystemState: the events of the hardware, before any software sees them.
const uint CG_EVENT_SOURCE_STATE_HID_SYSTEM = 1;
// kCGAnyInputEventType, `(CGEventType)~0`: any input event.
const uint CG_ANY_INPUT_EVENT_TYPE          = 0xFFFFFFFF;
// The session dictionary key that holds whether the screen is locked. UNVERIFIED: see the header.
const String SESSION_SCREEN_IS_LOCKED       = "CGSSessionScreenIsLocked";

extern fn double cg_event_source_seconds_since_last_event_type(
	uint state_id,
	uint event_type
) @cname("CGEventSourceSecondsSinceLastEventType");
extern fn void* cg_session_copy_current_dictionary() @cname("CGSessionCopyCurrentDictionary");
extern fn void* cf_dictionary_get_value(void* dictionary, void* key) @cname("CFDictionaryGetValue");
extern fn bool cf_boolean_get_value(void* boolean) @cname("CFBooleanGetValue");

<* Seconds since the last input event of any kind, from the hardware event source. *>
fn double hid_idle_seconds()
{
	return cg_event_source_seconds_since_last_event_type(CG_EVENT_SOURCE_STATE_HID_SYSTEM, CG_ANY_INPUT_EVENT_TYPE);
}

<*
 Whether the screen is locked, from the window server's session dictionary. An absent key is
 unknown, not "unlocked": the key is UNVERIFIED on hardware, and a wrong key must not read as a
 permanent "not locked".

 @return "true or false; empty when the dictionary or the key cannot be read"
*>
fn Maybe{bool} screen_locked()
{
	cf::Ref session = cf::adopt(cg_session_copy_current_dictionary());
	defer session.close();
	if (session.is_nil()) return { };
	cf::Ref key = cf::from_string(SESSION_SCREEN_IS_LOCKED);
	defer key.close();
	void* value = cf_dictionary_get_value(session.ptr, key.ptr);
	if (value == null) return { };
	if (cf::type_of(value) != cf::boolean_type_id()) return { };
	return maybe::value(cf_boolean_get_value(value));
}