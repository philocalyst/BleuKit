<*
 What the server does with a command from the shell, and the announcements that
 go out when a notification leaves the screen. Everything here runs on the worker.
*>
module bleu::notify::fdo @feat(LINUX);
import std::time, bleu::error, bleu::observe, bleu::operation, bleu::dbus::value, bleu::dbus::server, bleu::rt::poller, bleu::rt::worker, bleu::notify, bleu::notify::store;

<*
 Publish the centre's current state. Nothing is published when it has not
 changed, so listeners wake only on a real change.
*>
fn void publish(Session* s)
{
	Snapshot{notify::State}* snapshot = s.hub.begin();
	s.store.fill(&snapshot.value, snapshot.allocator());
	snapshot.value.serving = s.serving;
	s.hub.publish_if_changed(snapshot);
}

// The server is leaving: say so once, so that `latest()` does not claim a name it no longer holds.
fn void stopped(Session* s)
{
	s.serving = false;
	publish(s);
}

// A notification's timeout passed.
fn void? expire(Session* s, notify::NoteId id)
{
	if (!s.store.close(id)) return;
	announce_closed(s, id, notify::CloseReason.EXPIRED)!;
	publish(s);
}

// Run one command from the mailbox and complete its operation, if it has one.
fn void? execute(Session* s, notify::Command* command)
{
	switch (command.kind)
	{
		case notify::CommandKind.CLOSE: close_by_request(s, command)!;
		case notify::CommandKind.INVOKE_ACTION: invoke(s, command)!;
		case notify::CommandKind.SET_DO_NOT_DISTURB:
			s.store.set_do_not_disturb(command.flag);
			publish(s);
		case notify::CommandKind.CLEAR_HISTORY:
			s.store.clear_history();
			publish(s);
	}
}

fn void? close_by_request(Session* s, notify::Command* command)
{
	Operation{bool}* operation = command.operation;
	if (!s.store.close(command.id))
	{
		finish(operation, error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no open notification %d", command.id));
		return;
	}
	cancel(s, command.id);
	if (catch err = announce_closed(s, command.id, command.reason))
	{
		finish(operation, err);
		return err~;
	}
	publish(s);
	finish_ok(operation, true);
}

// Invoke an action: announce it, then close the notification unless it is resident.
fn void? invoke(Session* s, notify::Command* command)
{
	Operation{bool}* operation = command.operation;
	store::Entry* e            = s.store.open(command.id);
	if (e == null)
	{
		finish(operation, error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no open notification %d", command.id));
		return;
	}
	String key = (String)command.key[0:(sz)command.key_len];
	if (!offers(e, key))
	{
		finish(
			operation,
			error::raise(
				error::INVALID_ARGUMENT,
				error::Domain.INTERNAL,
				0,
				"notification %d has no action '%s'",
				command.id,
				key
			)
		);
		return;
	}
	bool resident = e.note.resident;
	if (catch err = announce_action(s, command.id, key))
	{
		finish(operation, err);
		return err~;
	}
	if (!resident)
	{
		s.store.close(command.id);
		cancel(s, command.id);
		if (catch err = announce_closed(s, command.id, notify::CloseReason.CLOSED_BY_CALL))
		{
			finish(operation, err);
			return err~;
		}
	}
	publish(s);
	finish_ok(operation, true);
}

// The default action is always there; the others are the ones the application sent.
fn bool offers(store::Entry* e, String key)
{
	if (key == "default") return true;
	foreach (action : e.note.actions) if (action.key == key) return true;
	return false;
}

// Complete a command's operation (the worker's reference is released with it).
fn void finish(Operation{bool}* operation, fault failure)
{
	if (operation == null) return;
	(void)operation.fail(failure);
	operation.release();
}

<* Complete an operation as succeeded. *>
fn void finish_ok(Operation{bool}* operation, bool value)
{
	if (operation == null) return;
	(void)operation.succeed(value);
	operation.release();
}

<* Refuse a command that cannot be served: its operation fails UNAVAILABLE. *>
fn void refuse(notify::Command* command)
{
	finish(command.operation, error::UNAVAILABLE);
}

<*
 Keep refusing commands, until the server is stopped, so that nobody waits forever
 on an operation of a server that has gone. Called after the server has stopped
 serving, either because it was stopped or because the bus was lost.
*>
fn void refuse_until_stopped(Allocator allocator, Host{Command}* host)
{
	Poller wake;
	if (catch wake.init(allocator, host.wakeup(), 1))
	{
		// No wake-up means nothing can be waited for: refuse what is queued now, and stop.
		refuse_queued(host);
		return;
	}
	defer wake.free();
	while (true)
	{
		usz taken = refuse_queued(host);
		if (taken == 0 && host.stopping()) return;
		if (catch wake.wait())
		{
			// The wait itself failed: refuse what is queued and stop rather than spin.
			refuse_queued(host);
			return;
		}
	}
}

// Refuse every command in the mailbox; returns how many there were.
fn usz refuse_queued(Host{Command}* host)
{
	notify::Command[COMMAND_BATCH] commands;
	usz total = 0;
	while (true)
	{
		usz taken = host.mailbox().take_all(commands[..]);
		if (taken == 0) return total;
		for (usz k = 0; k < taken; k++) refuse(&commands[k]);
		total += taken;
	}
}

// Cancel the expiry timer of `id`, when it has one.
fn void cancel(Session* s, notify::NoteId id)
{
	if (catch s.timers.cancel((usz)id))
	{
		// No timer was pending: the notification never expired on its own.
	}
}

// Tell the bus that `id` closed, and why. A failed signal is returned: the bus is gone, and the server stops.
fn void? announce_closed(Session* s, notify::NoteId id, notify::CloseReason reason)
{
	@pool()
	{
		s.objects.emit_signal(
			OBJECT_PATH,
			INTERFACE,
			"NotificationClosed",
			{ value::u32(id), value::u32((uint)reason) }
		)!;
	};
	emit(s, { .kind = notify::EventKind.CLOSED, .id = id, .reason = reason });
}

// Tell the bus that the user invoked `key` on `id`, and tell the shell.
fn void? announce_action(Session* s, notify::NoteId id, String key)
{
	@pool()
	{
		s.objects.emit_signal(OBJECT_PATH, INTERFACE, "ActionInvoked", { value::u32(id), value::str(tmem, key)!! })!;
	};
	emit(s, { .kind = notify::EventKind.ACTION_INVOKED, .id = id, .action_key = key });
}

// Deliver an event to every subscriber. The packet owns a copy of the event's strings.
fn void emit(Session* s, notify::Event event)
{
	Snapshot{notify::Event}* packet = s.hub.emit_begin();
	packet.value = event;
	packet.value.action_key = event.action_key.copy(packet.allocator());
	s.hub.emit(packet);
}