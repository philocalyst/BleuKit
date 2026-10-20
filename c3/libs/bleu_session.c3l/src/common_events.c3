<*
 Publishing changes: transients to the event stream, and the rule by which a platform
 change updates the backend's own copy of the state. Shared by every backend; no OS names.
*>
module bleu::session;
import std::collections::maybe, std::time, bleu::observe;

<*
 Announce `kind` to every reader of the hub's events.

 @param watch : "The idle watch an IDLE or RESUMED belongs to; 0 otherwise"
 @param threshold : "The idle time an IDLE or RESUMED refers to; zero otherwise"
*>
fn void emit(SessionHub* hub, EventKind kind, ulong watch = 0, Duration threshold = time::DURATION_ZERO)
{
	Snapshot{Event}* packet = hub.emit_begin();
	packet.value = { .kind = kind, .watch = watch, .threshold = threshold };
	hub.emit(packet);
}

<*
 Apply one platform change to the backend's copies of `locked` and `sleeping`, then announce
 it. The caller publishes the next snapshot afterwards, so a reader that wakes on the event
 finds the state already updated.

 @param kind : "LOCKED, UNLOCKED, WILL_SLEEP or DID_WAKE"
 @require kind != EventKind.IDLE && kind != EventKind.RESUMED : "idle edges belong to their watch, not to the state"
*>
fn void apply_transition(EventKind kind, Maybe{bool}* locked, bool* sleeping, SessionHub* hub)
{
	if (kind == EventKind.LOCKED) *locked = maybe::value(true);
	else if (kind == EventKind.UNLOCKED) *locked = maybe::value(false);
	else if (kind == EventKind.WILL_SLEEP) *sleeping = true;
	else *sleeping = false;
	emit(hub, kind);
}
