<*
 The portal backend: org.freedesktop.portal.GlobalShortcuts on the session bus.

 The portal binds shortcuts per session, and a session accepts one BindShortcuts call. So a
 "round" always closes the previous session, creates a new one, lists the shortcuts the portal
 remembers for this application, and binds the whole set of registrations at once. The compositor
 shows its own dialog for the binding, so the user may refuse some of them; the Response says which.
 Every request answers on a Request object (see `portal_path.c3`), and the worker waits for that
 answer on its poller. Only one request is in flight at a time.

 Source of every name and rule: xdg-desktop-portal data/org.freedesktop.portal.GlobalShortcuts.xml,
 Request.xml and Session.xml (version 2 of the interface), and the shortcuts specification for the
 trigger strings. See docs/research/hotkey_impl.md.

 Priority 20; probed by asking the session bus for the portal and reading the interface `version`.
*>
module bleu::hotkey::portal @feat(LINUX);
import std::time, std::collections::maybe, std::collections::list, bleu::availability, bleu::dbus::connection, bleu::dbus::match, bleu::dbus::message, bleu::dbus::marshal, bleu::dbus::proxy, bleu::dbus::value, bleu::error, bleu::hotkey, bleu::hotkey::portal_path, bleu::operation, bleu::rt::poller, bleu::rt::worker, bleu::service;

const String PORTAL_NAME = "org.freedesktop.portal.Desktop";
const String PORTAL_PATH = "/org/freedesktop/portal/desktop";
const String GLOBAL_SHORTCUTS_IFACE = "org.freedesktop.portal.GlobalShortcuts";
const String REQUEST_IFACE = "org.freedesktop.portal.Request";
const String SESSION_IFACE = "org.freedesktop.portal.Session";

// The poller tag of the bus connection. The worker's wake-up is not tagged (see bleu_rt).
const usz CONNECTION_TAG = 1;

// How long the worker sleeps when nothing happens: it retries a lost connection on each tick.
const Duration TICK = (Duration)500_000; // 0.5 s in microseconds

// Response codes of org.freedesktop.portal.Request.Response.
const uint RESPONSE_SUCCESS = 0;
const uint RESPONSE_CANCELLED = 1;
const uint RESPONSE_OTHER = 2;

// What the current round waits for.
enum Step : char
{
	IDLE,     // no round in flight
	CREATING, // CreateSession: a Request whose Response carries session_handle
	LISTING,  // ListShortcuts: what the portal remembers; optional, a failure is not fatal
	BINDING,  // BindShortcuts: the user answers the compositor's dialog
}

<* A registration waiting for the round that completes it. *>
struct Waiting
{
	Task* operation; // the reference this entry owns
	String id;       // owned copy
	Binding removed; // UNREGISTER only: the binding that was removed, its strings owned
	bool removal;
}

<* The backend's state. Touched only on the worker thread, except through the command mailbox. *>
struct Backend
{
	Allocator allocator;
	HotkeyHub* hub;
	Connection connection;
	bool connected;
	uint version;              // GlobalShortcuts interface version; 0 when the interface is absent
	Availability registration; // whether shortcuts can be bound right now, and why not
	String sender;             // our unique bus name, owned
	String session;            // the session of the last round, owned; "" when none
	uint tokens;               // counter for handle tokens
	Step step;
	String request;            // owned: the Request path the current step answers on
	SubscriptionId response_subscription;
	bool response_subscribed;
	bool answered;             // the Response for `request` has arrived
	uint answer_code;          // its response code
	bool reply_failed;         // the call of the current step failed
	fault reply_fault;
	String reply_handle;       // owned: the Request path the reply named, when it differs from `request`
	List{Binding} bindings;    // the registrations, in the order they were made
	List{Waiting} waiting;     // accepted, not yet in a round
	List{Waiting} in_round;    // completed by the current round
	bool dirty;                // a round must run
}

const Driver DRIVER = {
	.info = { "portal", "xdg-desktop-portal GlobalShortcuts (org.freedesktop.portal.Desktop)", 20 },
	.id = PORTAL,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

<*
 Whether the session bus has the portal and the portal offers GlobalShortcuts (its `version` property
 can be read). The connection used for the check is closed before returning.
*>
fn bool probe(Options* options)
{
	Connection connection;
	connection.init(mem);
	defer connection.free();
	if (catch connection.open_session()) return false;
	defer connection.close();
	if (try owned = connection.name_has_owner(PORTAL_NAME))
	{
		if (!owned) return false;
	}
	else
	{
		return false;
	}
	if (try shortcuts = proxy::for_object(&connection, PORTAL_NAME, PORTAL_PATH, GLOBAL_SHORTCUTS_IFACE))
	{
		if (try version = shortcuts.get_u32("version")) return version > 0;
	}
	return false;
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.set(
		Cap.REGISTER,
		availability::no(
			availability::Reason.DEGRADED,
			"Each round opens the compositor's shortcut dialog, and the user may refuse shortcuts"
		)
	);
	capabilities.set(
		Cap.UNREGISTER,
		availability::no(
			availability::Reason.DEGRADED,
			"The portal has no unbind: removing a shortcut binds the rest again in a new session"
		)
	);
	capabilities.set(
		Cap.CONFLICT_REPORT,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"The portal does not report a clash with another application's shortcut"
		)
	);
	capabilities.set(
		Cap.ACTIVATION_TOKEN,
		availability::no(
			availability::Reason.DEGRADED,
			"The token comes only when the compositor supplies one"
		)
	);
	Backend* backend = alloc::new(allocator, Backend);
	backend.allocator = allocator;
	backend.registration = availability::no(availability::Reason.BACKEND_STOPPED, "Not connected to the portal yet");
	backend.bindings.init(allocator);
	backend.waiting.init(allocator);
	backend.in_round.init(allocator);
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	Backend* b = (Backend*)state;
	foreach (binding : b.bindings) free_binding(b.allocator, &binding);
	b.bindings.free();
	b.waiting.free();
	b.in_round.free();
	set_text(&b.sender, "", b.allocator);
	set_text(&b.session, "", b.allocator);
	set_text(&b.request, "", b.allocator);
	set_text(&b.reply_handle, "", b.allocator);
	alloc::free(allocator, b);
}

fn void run(void* state, HotkeyHub* hub, Host{Command}* host)
{
	Backend* b = (Backend*)state;
	b.hub = hub;
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	// The connection is created here, on the worker: a Connection records the thread that uses it.
	if (catch connect(b, &poller))
	{
		// The portal is not reachable yet; each tick tries again.
	}
	publish(b);
	Command[8] commands;
	while (!host.stopping())
	{
		// Sleeps until a tick passes or the bus or the mailbox has something.
		if (catch poller.wait(TICK))
		{
			// TIMEOUT is the normal tick.
		}
		if (b.connected)
		{
			if (catch b.connection.process()) disconnect(b, &poller);
		}
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++) accept(b, commands[i]);
		if (!b.connected)
		{
			if (catch connect(b, &poller))
			{
				// Still unreachable; the registration state says so.
			}
		}
		advance(b);
		publish(b);
	}
	disconnect(b, &poller);
	// Requests that arrived after the last take are refused, so no caller waits for ever.
	while (true)
	{
		usz rest = host.mailbox().take_all(commands[..]);
		if (rest == 0) break;
		for (usz i = 0; i < rest; i++) refuse_command(commands[i], error::DISCONNECTED, "The shortcut service is closing");
	}
}

<*
 Open the session bus, subscribe to the portal's signals, register the connection with the poller and
 read the interface version. A missing interface is not a failure here: the registration says why.
 On failure nothing stays open.

 @return? error::UNAVAILABLE : "when the session bus cannot be reached"
*>
fn void? connect(Backend* b, Poller* poller)
{
	b.connection.init(b.allocator);
	if (catch err = b.connection.open_session())
	{
		b.connection.free();
		return err~;
	}
	if (catch err = subscribe_signals(b))
	{
		b.connection.close();
		b.connection.free();
		return err~;
	}
	int fd = b.connection.fd()!;
	if (catch err = poller.add({ .handle = (rt::Native)fd, .interest = { .readable = true }, .tag = CONNECTION_TAG }))
	{
		b.connection.close();
		b.connection.free();
		return err~;
	}
	b.connected = true;
	set_text(&b.sender, b.connection.name_on_bus(), b.allocator);
	read_version(b);
	// A connection that comes back re-binds whatever is still registered.
	if (b.bindings.len() > 0) b.dirty = true;
}

// The GlobalShortcuts `version`; a missing interface is the registration's reason, not an error.
fn void read_version(Backend* b)
{
	b.version = 0;
	if (try shortcuts = proxy::for_object(&b.connection, PORTAL_NAME, PORTAL_PATH, GLOBAL_SHORTCUTS_IFACE))
	{
		if (try version = shortcuts.get_u32("version"))
		{
			b.version = version;
			b.registration = availability::YES;
			return;
		}
	}
	b.registration = availability::no(
		availability::Reason.BACKEND_MISSING,
		"The portal does not offer org.freedesktop.portal.GlobalShortcuts"
	);
}

<*
 Close the connection and take it out of the poller. Whatever the connection was doing is over:
 requests in flight fail with DISCONNECTED, and registrations go back to being pending, to be
 bound again when the portal returns.
*>
fn void disconnect(Backend* b, Poller* poller)
{
	if (!b.connected) return;
	b.connected = false;
	if (catch poller.remove(CONNECTION_TAG))
	{
		// Not registered: nothing to remove.
	}
	b.connection.close();
	b.connection.free();
	b.response_subscribed = false;
	set_text(&b.session, "", b.allocator);
	abort_round(b, error::DISCONNECTED, "The connection to the portal went away", PENDING);
	b.registration = availability::no(
		availability::Reason.BACKEND_STOPPED,
		"The connection to the portal was lost; it is retried"
	);
}

// The signals every session shares: Activated, Deactivated and ShortcutsChanged from the portal.
fn void? subscribe_signals(Backend* b)
{
	if (catch err = subscribe_signal(b, "Activated", &on_activated)) return err~;
	if (catch err = subscribe_signal(b, "Deactivated", &on_deactivated)) return err~;
	if (catch err = subscribe_signal(b, "ShortcutsChanged", &on_shortcuts_changed)) return err~;
}

fn void? subscribe_signal(Backend* b, String member, SignalHandler handler) @private
{
	match::Match rule;
	rule.init(b.allocator);
	rule.with_type(message::MessageType.SIGNAL)!!;
	rule.with_sender(PORTAL_NAME)!!;
	rule.with_interface(GLOBAL_SHORTCUTS_IFACE)!!;
	rule.with_member(member)!!;
	b.connection.subscribe(rule, handler, b)!;
}

// Copy `text` into `*field` with `allocator`, freeing the text it replaces. "" owns nothing.
fn void set_text(String* field, String text, Allocator allocator)
{
	if (field.len > 0) alloc::free(allocator, field.ptr);
	*field = dup(text, allocator);
}

// A copy of `text` in `allocator`; the empty string needs no storage.
fn String dup(String text, Allocator allocator)
{
	if (text.len == 0) return "";
	return text.copy(allocator);
}

// Free a string made by `dup`.
fn void drop(String text, Allocator allocator)
{
	if (text.len > 0) alloc::free(allocator, text.ptr);
}

// Publish the registrations and the registration state, if they changed since the last publication.
fn void publish(Backend* b)
{
	Snapshot{State}* snapshot = b.hub.begin();
	Allocator arena           = snapshot.allocator();
	Binding[] copies          = {};
	if (b.bindings.len() > 0)
	{
		copies = alloc::new_array(arena, Binding, b.bindings.len());
		for (sz i = 0; i < b.bindings.len(); i++) copies[i] = copy_binding(b.bindings.get(i), arena);
	}
	snapshot.value = { .bindings = copies, .portal_version = b.version, .registration = b.registration };
	b.hub.publish_if_changed(snapshot);
}
