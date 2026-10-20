<*
 Sending notifications as a client: asking the platform's notification centre to
 show one. Linux calls `Notify` on the freedesktop server (ours, or any other
 daemon that owns the name); macOS posts a UNNotificationRequest. Windows is
 UNSUPPORTED for now: see `sender_toast.c3`.

 Sender* sender = notify::sender::open(mem)!;
 defer sender.close();
 NoteId id = sender.send(notify::sender::new_request("Build finished"))!;

 A request that uses a feature the backend does not offer is refused with that
 feature's availability; nothing is silently dropped. Sending is synchronous: it
 returns when the platform has taken the request. A `Sender` belongs to the thread
 that opened it.
*>
module bleu::notify::sender;
import std::collections::enummap, bleu::error, bleu::availability, bleu::notify;

<* What a request can ask for beyond a summary. A backend says which of these it sends. *>
enum Feature : char
{
	BODY,
	ACTIONS,
	IMAGE,   // `image_path`: a file or an icon name
	REPLACE, // `replaces_id`
	EXPIRY,  // `expire_ms` other than -1
	URGENCY, // `urgency` other than NORMAL
	CATEGORY,
	SOUND,   // `sound_name`
}

<* Availability of each `Feature` on this backend. *>
alias Features = EnumMap{Feature, Availability};

<*
 A notification to show. Build it with `new_request` and change what it needs:
 a literal would have urgency LOW and expiry 0 (never), which are not the defaults.
*>
struct Request
{
	String app_name;
	notify::NoteId replaces_id; // 0: a new notification
	String app_icon;      // theme name or file URI, empty for none
	String summary;
	String body;          // plain text; the centre sanitises markup on its side
	notify::Action[] actions;
	notify::Urgency urgency;
	String category;      // "class.specific", e.g. "im.received"
	String desktop_entry; // the application's desktop file id, e.g. "chat"
	String image_path;    // file URI or theme name
	String sound_name;    // themed sound name
	bool suppress_sound;  // the sender plays its own sound
	bool resident;        // stays open after an action
	bool transient;       // never kept in history
	int expire_ms;        // -1 the server's default, 0 never, more than 0 milliseconds
}

<* A request with the defaults: a normal notification that uses the server's timeout. *>
fn Request new_request(String summary)
{
	return { .summary = summary, .urgency = notify::Urgency.NORMAL, .expire_ms = -1 };
}

<* The sender of one backend: its state and what it can send. *>
struct Sender
{
	Allocator allocator;
	SenderDriver* driver;
	void* state;
	Features features;
}

<* Backend entry points. A backend file defines a `SenderDriver` constant. *>
alias SenderOpenFn = fn void*?(Allocator allocator, Features* features);
alias SenderCloseFn = fn void(Allocator allocator, void* state);
alias SenderSendFn = fn notify::NoteId?(void* state, Request* request);

struct SenderDriver
{
	BackendInfo info;
	SenderOpenFn open_fn;
	SenderCloseFn close_fn;
	SenderSendFn send_fn;
}

<*
 Open a sender on the first platform backend that works here.

 @return? error::UNSUPPORTED : "This platform has no notification sender yet (the reason is in error::last())"
 @return? error::UNAVAILABLE : "The platform's notification service is not reachable from this process"
 @return? error::PERMISSION_DENIED : "The user has not allowed notifications for this application"
*>
fn Sender*? open(Allocator allocator)
{
	SenderDriver* driver = platform_sender_driver();
	Sender* self = alloc::new(allocator, Sender);
	*self = { .allocator = allocator, .driver = driver };
	void*? state = driver.open_fn(allocator, &self.features);
	if (catch err = state)
	{
		alloc::free(allocator, self);
		return err~;
	}
	self.state = state;
	return self;
}

<* Release the sender and whatever it holds. *>
fn void Sender.close(&self)
{
	self.driver.close_fn(self.allocator, self.state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend, for diagnostics ("fdo", "un"). *>
fn String Sender.backend_name(&self) => self.driver.info.name;

<* Whether this backend sends `feature`, and if not, why. *>
fn Availability Sender.capability(&self, Feature feature) => self.features.values[feature.ordinal];

<*
 Show `request`, and return its id (never zero). A replacement returns the id it
 replaced.

 @return? error::UNSUPPORTED : "The request uses a feature this backend does not send"
 @return? error::UNAVAILABLE : "The notification centre is not running"
 @return? error::PERMISSION_DENIED : "The platform refused the notification"
 @return? error::BACKEND_FAILURE : "The platform reported a failure; the message says which"
*>
fn notify::NoteId? Sender.send(&self, Request request)
{
	require(self, request.body.len > 0, BODY)!;
	require(self, request.actions.len > 0, ACTIONS)!;
	require(self, request.image_path.len > 0, IMAGE)!;
	require(self, request.replaces_id != 0, REPLACE)!;
	require(self, request.expire_ms != -1, EXPIRY)!;
	require(self, request.urgency != notify::Urgency.NORMAL, URGENCY)!;
	require(self, request.category.len > 0, CATEGORY)!;
	require(self, request.sound_name.len > 0, SOUND)!;
	return self.driver.send_fn(self.state, &request);
}

// Refuse when the request uses `feature` and the backend does not send it.
fn void? require(Sender* self, bool used, Feature feature)
{
	if (!used) return;
	Availability availability = self.features.values[feature.ordinal];
	if (!availability.ok()) return availability.refusal()~;
}
