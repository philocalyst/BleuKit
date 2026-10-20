<*
 Notification subscriptions: NSNotificationCenter, NSDistributedNotificationCenter
 and NSWorkspace (sleep/wake, screen lock, appearance).

 Two styles, both delivered on the posting thread:
 * block-based (`observe`): the handler is a C3 function plus a user pointer,
 wrapped in an Objective-C block (`block.c3`);
 * selector-based (`observe_selector`): the observer is an object of a class
 built with `ClassBuilder` (`class.c3`) whose method receives the notification.

 Threading: the posting thread is AppKit's main thread for workspace
 notifications and an arbitrary thread for distributed ones. Handlers must
 only enqueue work to the owning service (ARCHITECTURE.md, "Threads").

 Sources: Apple objc4/Foundation method names (`addObserverForName:object:queue:usingBlock:`,
 `addObserver:selector:name:object:`, `removeObserver:`) appear in objc2-foundation
 `src/generated/NSNotification.rs`. Workspace notification names: objc2-app-kit
 `src/generated/NSWorkspace.rs`. The distributed names: tao
 `src/platform_impl/macos/window_delegate.rs` (AppleInterfaceThemeChangedNotification).
*>
module bleu::objc::notify @feat(DARWIN) @link("AppKit.framework");
import std::os::darwin::objc, bleu::objc, bleu::objc::foundation, bleu::error;

<* Which notification center a subscription uses. *>
enum CenterKind : char
{
	DEFAULT,     // NSNotificationCenter for this process
	DISTRIBUTED, // NSDistributedNotificationCenter: all processes of this user
	WORKSPACE,   // NSWorkspace's own center: sleep, wake, mounts, sessions
}

<* `NSWorkspaceWillSleepNotification`: the system is about to sleep. *>
extern const ObjId NS_WORKSPACE_WILL_SLEEP_NOTIFICATION @cname("NSWorkspaceWillSleepNotification");
<* `NSWorkspaceDidWakeNotification`: the system has woken. *>
extern const ObjId NS_WORKSPACE_DID_WAKE_NOTIFICATION @cname("NSWorkspaceDidWakeNotification");
<* `NSWorkspaceScreensDidSleepNotification`: the displays went to sleep. *>
extern const ObjId NS_WORKSPACE_SCREENS_DID_SLEEP_NOTIFICATION @cname("NSWorkspaceScreensDidSleepNotification");
<*
 `NSWorkspaceSessionDidResignActiveNotification`: the user session was switched away (fast user switching, lock screen).
*>
extern const ObjId NS_WORKSPACE_SESSION_DID_RESIGN_ACTIVE_NOTIFICATION @cname("NSWorkspaceSessionDidResignActiveNotification");

<* Distributed notification posted when the system appearance (light/dark) changes. *>
const ZString DISTRIBUTED_APPEARANCE_CHANGED = "AppleInterfaceThemeChangedNotification";

<*
 Distributed notification posted when the screen is locked. Not verified against
 a second independent source in this environment; see docs/research/bleu_objc.md.
*>
const ZString DISTRIBUTED_SCREEN_LOCKED = "com.apple.screenIsLocked";

<*
 The notification center of `kind`, borrowed.

 @return "the center; nil only if the framework is not loaded"
*>
fn ObjId center_of(CenterKind kind)
{
	switch (kind)
	{
		case DEFAULT:
			return objc::class_named("NSNotificationCenter").send(ObjId, "defaultCenter");
		case DISTRIBUTED:
			return objc::class_named("NSDistributedNotificationCenter").send(ObjId, "defaultCenter");
		case WORKSPACE:
			return objc::class_named("NSWorkspace").send(ObjId, "sharedWorkspace").send(ObjId, "notificationCenter");
	}
}

<* A block-based observer. Owns the handler's block until `close`. *>
struct BlockSubscription
{
	Obj center;
	Obj token;
	Block block;
}

<*
 Observe `name` on the center of `kind`. `handler` receives the NSNotification
 object (borrowed for the call) and `user`.

 Closing the subscription removes the observer. Keep `user` alive until then.

 @return? error::BACKEND_FAILURE : "when the center cannot be used"
*>
fn BlockSubscription? observe(CenterKind kind, ObjId name, IdHandler handler, void* user)
{
	ObjId center = center_of(kind);
	if (!center || !name) return error::raise(
		error::BACKEND_FAILURE,
		error::Domain.INTERNAL,
		0,
		"no notification center or name"
	)~;
	objc::Block block = objc::id_block(handler, user);
	ObjId token       = center.send(ObjId, "addObserverForName:object:queue:usingBlock:", name, null, null, block.id());
	return {
		.center = objc::borrow(center),
		.token = objc::borrow(token),
		.block = block,
	};
}

<* Remove the observer, release the block, and become empty. Idempotent. *>
fn void BlockSubscription.close(&self)
{
	if (self.token.ptr) self.center.send_void("removeObserver:", self.token.ptr);
	self.token.close();
	self.center.close();
	self.block.release();
}

<* A selector-based observer. The observer object must outlive the subscription. *>
struct SelectorSubscription
{
	Obj center;
	ObjId observer;
}

<*
 Observe `name` on the center of `kind`, delivering to `observer`'s method
 `selector`, which must have the signature `void (id self, SEL _cmd, NSNotification *)`.

 @return? error::BACKEND_FAILURE : "when the center cannot be used"
*>
fn SelectorSubscription? observe_selector(CenterKind kind, ObjId observer, ObjSel selector, ObjId name)
{
	ObjId center = center_of(kind);
	if (!center || !observer || !name) return error::raise(
		error::BACKEND_FAILURE,
		error::Domain.INTERNAL,
		0,
		"no notification center, observer or name"
	)~;
	center.send_void("addObserver:selector:name:object:", observer, selector, name, null);
	return { .center = objc::borrow(center), .observer = observer };
}

<* Remove every registration of the observer on the center, and release the center. Idempotent. *>
fn void SelectorSubscription.close(&self)
{
	if (self.center.ptr && self.observer) self.center.send_void("removeObserver:", self.observer);
	self.observer = null;
	self.center.close();
}

<*
 Make an `NSString` from a Bleu string constant such as `DISTRIBUTED_APPEARANCE_CHANGED`.
 The result is owned.
*>
fn Obj name_of(ZString name) => foundation::from_string(name.str_view());