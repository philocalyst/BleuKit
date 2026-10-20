<*
 macOS sender: UNUserNotificationCenter.

 Calls, from Apple's UserNotifications framework (research note docs/research/media_notify_tray.md 2.2,
 `APPLE-JSON` usernotifications_*.json): `currentNotificationCenter`,
 `requestAuthorizationWithOptions:completionHandler:`, `UNMutableNotificationContent`,
 `UNNotificationRequest requestWithIdentifier:content:trigger:` and
 `addNotificationRequest:withCompletionHandler:`. The option bits (badge 1, sound 2,
 alert 4) are from the SDK's UNUserNotificationCenter.h; that header was not fetched
 here (UNVERIFIED).

 An unbundled process cannot post: the centre refuses without a bundle identifier,
 so `open` checks for one first and reports UNAVAILABLE with the reason.

 Compiled only: no macOS machine was available. Every call goes through bleu_objc.
*>
module bleu::notify::sender_un @feat(DARWIN) @link("UserNotifications.framework");
import std::os::darwin::objc, std::thread, std::time, bleu::availability, bleu::deadline, bleu::error, bleu::objc, bleu::objc::foundation, bleu::notify, bleu::notify::sender;

const ulong OPTION_BADGE = 1; // UNAuthorizationOptionBadge
const ulong OPTION_SOUND = 2; // UNAuthorizationOptionSound
const ulong OPTION_ALERT = 4; // UNAuthorizationOptionAlert
const Duration AUTHORIZATION_TIMEOUT = (Duration)60_000_000; // the user may take a while over the prompt
const Duration POST_TIMEOUT = (Duration)10_000_000;

// Shared with the completion handlers, which run on another thread. One request at a time.
struct UnSender
{
	Allocator allocator;
	Mutex mutex;
	ConditionVariable changed;
	bool answered;
	bool granted;
	objc::Obj failure;
	notify::NoteId next_id;
}

const sender::SenderDriver DRIVER = {
	.info = { "un", "UNUserNotificationCenter (macOS, requires an app bundle)", 10 },
	.open_fn = &open_un,
	.close_fn = &close_un,
	.send_fn = &send_un,
};

fn void*? open_un(Allocator allocator, sender::Features* features)
{
	features.init(availability::no(availability::Reason.UNSUPPORTED_BACKEND, "not sent by this backend"));
	features.set(sender::Feature.BODY, availability::YES);
	features.set(sender::Feature.REPLACE, availability::YES);
	features.set(
		sender::Feature.ACTIONS,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "UNNotificationCategory actions are not registered")
	);
	features.set(
		sender::Feature.IMAGE,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "attachments are not built")
	);
	features.set(
		sender::Feature.EXPIRY,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "macOS notifications have no timeout the app sets")
	);
	features.set(
		sender::Feature.URGENCY,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "interruption levels are not set")
	);
	features.set(
		sender::Feature.CATEGORY,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "notification categories are not set")
	);
	features.set(
		sender::Feature.SOUND,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "UNNotificationSound is not set")
	);
	if (!has_bundle_identifier())
	{
		return error::raise(
			error::UNAVAILABLE,
			error::Domain.INTERNAL,
			0,
			"this process has no bundle identifier; UNUserNotificationCenter posts only from an app bundle"
		)~;
	}
	UnSender* self = alloc::new(allocator, UnSender);
	*self = { .allocator = allocator, .next_id = 1 };
	self.mutex.init()!!;
	self.changed.init()!!;
	if (catch err = authorize(self))
	{
		close_un(allocator, self);
		return err~;
	}
	return self;
}

fn void close_un(Allocator allocator, void* state)
{
	UnSender* self = (UnSender*)state;
	self.failure.close();
	self.mutex.destroy();
	self.changed.destroy()!!;
	alloc::free(allocator, self);
}

// True when the main bundle has an identifier, which UNUserNotificationCenter requires.
fn bool has_bundle_identifier()
{
	bool present = false;
	objc::@autorelease_pool()
	{
		ObjId bundle = objc::class_named("NSBundle").send(ObjId, "mainBundle");
		if (bundle)
		{
			ObjId identifier = bundle.send(ObjId, "bundleIdentifier");
			present = identifier ? true : false;
		}
	};
	return present;
}

fn objc::Obj center() => objc::borrow(objc::class_named("UNUserNotificationCenter").send(ObjId, "currentNotificationCenter"));

// Ask once for the permissions this sender uses. The user's answer decides every later send.
fn void? authorize(UnSender* self)
{
	objc::Obj center = center();
	defer center.close();
	Block handler = bool_error_block(&on_authorized, self);
	defer handler.release();
	self.answered = false;
	center.send_void(
		"requestAuthorizationWithOptions:completionHandler:",
		OPTION_BADGE | OPTION_SOUND | OPTION_ALERT,
		handler.id()
	);
	wait_for_answer(self, AUTHORIZATION_TIMEOUT)!;
	if (!self.granted)
	{
		return error::raise(
			error::PERMISSION_DENIED,
			error::Domain.INTERNAL,
			0,
			"the user has not allowed notifications for this application"
		)~;
	}
}

fn void on_authorized(void* user, bool success, ObjId error)
{
	UnSender* self = (UnSender*)user;
	self.mutex.lock()!!;
	self.granted = success;
	self.answered = true;
	self.changed.broadcast()!!;
	self.mutex.unlock();
}

// Post one request. A replacement reuses the identifier of the notification it replaces.
fn notify::NoteId? send_un(void* state, sender::Request* request)
{
	UnSender* self = (UnSender*)state;
	notify::NoteId id = request.replaces_id != 0 ? request.replaces_id : self.next_id;
	if (request.replaces_id == 0) self.next_id = id == notify::NoteId.max ? 1 : id + 1;
	objc::Obj content = objc::adopt(objc::class_named("UNMutableNotificationContent").send(ObjId, "new"));
	defer content.close();
	objc::Obj title = foundation::from_string(request.summary);
	defer title.close();
	content.send_void("setTitle:", title.ptr);
	if (request.body.len > 0)
	{
		objc::Obj text = foundation::from_string(request.body);
		defer text.close();
		content.send_void("setBody:", text.ptr);
	}
	objc::Obj identifier;
	@pool()
	{
		identifier = foundation::from_string(string::tformat("bleu.%d", id));
	};
	defer identifier.close();
	ObjId post = objc::class_named("UNNotificationRequest").send(
		ObjId,
		"requestWithIdentifier:content:trigger:",
		identifier.ptr,
		content.ptr,
		null
	);
	objc::Obj center = center();
	defer center.close();
	Block handler = id_block(&on_added, self);
	defer handler.release();
	self.answered = false;
	self.failure.close();
	center.send_void("addNotificationRequest:withCompletionHandler:", post, handler.id());
	wait_for_answer(self, POST_TIMEOUT)!;
	if (self.failure.ptr)
	{
		return foundation::raise_ns_error(self.failure.ptr, "posting the notification")~;
	}
	return id;
}

fn void on_added(void* user, ObjId error)
{
	UnSender* self = (UnSender*)user;
	self.mutex.lock()!!;
	if (error) self.failure = objc::borrow(error);
	self.answered = true;
	self.changed.broadcast()!!;
	self.mutex.unlock();
}

// Wait until a completion handler answered, or the time is up.
fn void? wait_for_answer(UnSender* self, Duration timeout)
{
	Deadline deadline = deadline::after(timeout);
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	while (!self.answered)
	{
		if (!deadline.wait(&self.changed, &self.mutex)) return TIMEOUT~;
	}
}
