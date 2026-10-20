<*
 The Accessibility API: whether this process may control other applications'
 windows, and the element of an application's focused window.

 Function names and the AXError success value: ApplicationServices (HIServices)
 headers. The Apple reference pages for these functions were not readable in this
 environment (the saved pages are error pages), so the signatures are UNVERIFIED
 beyond `AXIsProcessTrusted()`, which appears in an AppKit reference page
 (appkit_nsevent_addglobalmonitorforevents, read). `AXUIElementCopyAttributeValue`
 with a `CFTypeRef*` out-parameter is used the same way by Hammerspoon
 extensions/window/libwindow.m:334-335 (read): a second source for the call shape.
 The attribute and action names below are UNVERIFIED in this environment.

 Observed on: NOT RUN. Compiled for macos-aarch64 and macos-x64 only.
*>
module bleu::windows::macos_ax @feat(DARWIN) @link("ApplicationServices.framework");
import bleu::cf, bleu::error;

// kAXErrorSuccess: every call that succeeded.
const int AX_ERROR_SUCCESS = 0;

// Attribute and action names (HIServices AXAttributeConstants.h and AXActionConstants.h).
const String ATTRIBUTE_FOCUSED_WINDOW = "AXFocusedWindow";
const String ATTRIBUTE_CLOSE_BUTTON   = "AXCloseButton";
const String ATTRIBUTE_MINIMIZED      = "AXMinimized";
const String ACTION_RAISE             = "AXRaise";
const String ACTION_PRESS             = "AXPress";

extern fn bool ax_is_process_trusted() @cname("AXIsProcessTrusted");
extern fn cf::CFTypeRef ax_ui_element_create_application(int pid) @cname("AXUIElementCreateApplication");
extern fn int ax_ui_element_copy_attribute_value(
	cf::CFTypeRef element,
	cf::CFTypeRef attribute,
	cf::CFTypeRef* value
) @cname("AXUIElementCopyAttributeValue");
extern fn int ax_ui_element_set_attribute_value(
	cf::CFTypeRef element,
	cf::CFTypeRef attribute,
	cf::CFTypeRef value
) @cname("AXUIElementSetAttributeValue");
extern fn int ax_ui_element_perform_action(
	cf::CFTypeRef element,
	cf::CFTypeRef action
) @cname("AXUIElementPerformAction");

<* Whether this process is trusted for Accessibility (System Settings > Privacy & Security). *>
fn bool is_trusted() => ax_is_process_trusted();

<*
 The focused window of the application `pid`, owned by the caller.

 @return? error::BACKEND_FAILURE : "The application has no accessibility element or no focused window"
*>
fn cf::Ref? focused_window(int pid)
{
	cf::Ref application = cf::adopt(ax_ui_element_create_application(pid));
	defer application.close();
	if (application.is_nil()) return error::raise(
		error::BACKEND_FAILURE,
		error::Domain.INTERNAL,
		0,
		"no accessibility element for process %d",
		pid
	)~;
	return copy_attribute(application.ptr, ATTRIBUTE_FOCUSED_WINDOW);
}

<*
 A child element of `element`, owned by the caller.

 @return? error::BACKEND_FAILURE : "The attribute is missing or the call failed"
*>
fn cf::Ref? copy_attribute(cf::CFTypeRef element, String name)
{
	cf::Ref attribute = cf::from_string(name);
	defer attribute.close();
	cf::CFTypeRef value = null;
	int status          = ax_ui_element_copy_attribute_value(element, attribute.ptr, &value);
	if (status != AX_ERROR_SUCCESS || value == null)
	{
		return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.INTERNAL,
			status,
			"accessibility attribute %s",
			name
		)~;
	}
	return cf::adopt(value);
}

<* Set a boolean attribute of `element`, as `AXUIElementSetAttributeValue` does. *>
fn void? set_flag(cf::CFTypeRef element, String name, bool value)
{
	cf::Ref attribute = cf::from_string(name);
	defer attribute.close();
	cf::Ref flag = cf::from_bool(value);
	defer flag.close();
	int status = ax_ui_element_set_attribute_value(element, attribute.ptr, flag.ptr);
	if (status != AX_ERROR_SUCCESS) return error::raise(
		error::BACKEND_FAILURE,
		error::Domain.INTERNAL,
		status,
		"setting %s",
		name
	)~;
}

<* Perform an action (AXRaise, AXPress) on `element`. *>
fn void? perform(cf::CFTypeRef element, String action)
{
	cf::Ref name = cf::from_string(action);
	defer name.close();
	int status = ax_ui_element_perform_action(element, name.ptr);
	if (status != AX_ERROR_SUCCESS) return error::raise(
		error::BACKEND_FAILURE,
		error::Domain.INTERNAL,
		status,
		"performing %s",
		action
	)~;
}