<*
 Publishing changes: transients to the event stream, and the rule by which the platform
 changes recorded by a backend update its own copy of the state. Shared by every backend;
 no OS names.

 Order matters: a backend records the changes it saw, applies them to its copies, publishes
 the next snapshot, and only then announces the events. A reader woken by an event must find
 the state already updated.
*>
module bleu::session;
import std::collections::list, std::collections::maybe, std::time, bleu::error, bleu::observe, bleu::operation;

<* Announce `event` to every reader of the hub's events. *>
fn void emit(SessionHub* hub, Event event)
{
	Snapshot{Event}* packet = hub.emit_begin();
	packet.value = event;
	hub.emit(packet);
}

<*
 Apply the recorded changes to the backend's copies of `locked` and `sleeping`. Only LOCKED,
 UNLOCKED, WILL_SLEEP and DID_WAKE are changes of the state; idle edges belong to their watch.

 @param pending : "The events recorded since the last snapshot, in the order they happened"
*>
fn void apply_pending(List{Event}* pending, Maybe{bool}* locked, bool* sleeping)
{
	for (sz i = 0; i < pending.len(); i++)
	{
		EventKind kind = pending.get(i).kind;
		if (kind == EventKind.LOCKED)
		{
			*locked = maybe::value(true);
		}
		else if (kind == EventKind.UNLOCKED)
		{
			*locked = maybe::value(false);
		}
		else if (kind == EventKind.WILL_SLEEP)
		{
			*sleeping = true;
		}
		else if (kind == EventKind.DID_WAKE)
		{
			*sleeping = false;
		}
	}
}

<*
 Announce the recorded changes, in order, and forget them. Call after the snapshot that
 includes them has been published.
*>
fn void announce(List{Event}* pending, SessionHub* hub)
{
	for (sz i = 0; i < pending.len(); i++) emit(hub, pending.get(i));
	pending.clear();
}

<*
 Complete a request the worker did not run, when the backend stops or bails out before taking it:
 its operation fails with DISCONNECTED, so no waiter hangs. Watch commands need nothing, because
 their slots go with the worker. Registered with `Hub.start`; runs on the worker thread.
*>
fn void abandon_command(void* backend, Command* command)
{
	if (command.kind != CommandKind.REQUEST) return;
	SessionOperation* operation = command.operation;
	operation.fail(error::DISCONNECTED);
	operation.release();
}
