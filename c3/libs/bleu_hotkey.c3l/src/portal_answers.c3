<*
 The handlers the connection calls on the worker thread: the reply to a call, the Response of a
 Request, and the portal's signals. They record what arrived or emit an event; the round is driven
 by `advance`, which runs after the connection has processed its messages.
*>
module bleu::hotkey::portal @feat(LINUX);
import std::time::clock, std::collections::maybe, bleu::dbus::connection, bleu::dbus::message, bleu::dbus::marshal, bleu::dbus::value, bleu::error, bleu::hotkey, bleu::observe;

<*
 The reply to a call of the current step. A reply names the Request object the answer will come on;
 the Response is what carries the answer, so only the path is recorded here.
*>
fn void on_reply(void* context, Message* reply, error::Status status)
{
	Backend* b = (Backend*)context;
	if (status != error::Status.OK || reply == null)
	{
		b.reply_failed = true;
		b.reply_fault = status == error::Status.OK ? error::PROTOCOL : error::fault_of(status);
		return;
	}
	if (try reader = reply.reader())
	{
		if (try handle = reader.read_object_path())
		{
			set_text(&b.reply_handle, handle, b.allocator);
			return;
		}
	}
	b.reply_failed = true;
	b.reply_fault = error::PROTOCOL;
}

// The reply of a call that nothing waits for (Session.Close): there is nothing to record.
fn void ignore_reply(void* context, Message* reply, error::Status status)
{
}

<*
 The Response of the Request the current step waits for. Duplicates are ignored. A malformed
 Response is a protocol error for the step.
*>
fn void on_response(void* context, Message* signal)
{
	Backend* b = (Backend*)context;
	if (b.answered) return;
	if (catch err = read_response(b, signal))
	{
		b.reply_failed = true;
		b.reply_fault = err;
	}
}

fn void? read_response(Backend* b, Message* signal) @local
{
	marshal::Reader reader = signal.reader()!;
	uint code = reader.read_u32()!;
	@pool()
	{
		Value results = reader.read_value(tmem)!;
		if (code == RESPONSE_SUCCESS) apply_results(b, results)!;
	};
	b.answer_code = code;
	b.answered = true;
}

// Take the results the step asked for: the session handle, or the shortcuts the portal listed or bound.
fn void? apply_results(Backend* b, Value results) @local
{
	if (b.step == CREATING)
	{
		Value handle = results.dict_get("session_handle")!;
		set_text(&b.session, handle.as_string()!, b.allocator);
		return;
	}
	Value empty;
	Value? listing = results.dict_get("shortcuts");
	apply_shortcuts(b, listing ?? empty, b.step == BINDING);
}

<*
 Update the registrations from a list of `(sa{sv})` shortcuts. Each registration the list names takes
 its trigger text. When `binding` is set (BindShortcuts), a registration the list names is BOUND and
 one it does not is REFUSED.
*>
fn void apply_shortcuts(Backend* b, Value list, bool binding) @local
{
	for (sz i = 0; i < b.bindings.len(); i++)
	{
		Binding* entry = b.bindings.get_ref(i);
		bool found = false;
		String wanted = "";
		for (usz j = 0; j < list.count() && !found; j++)
		{
			if (try item = list.at(j))
			{
				String listed_id;
				String listed_trigger;
				if (read_entry(item, &listed_id, &listed_trigger) && listed_id == entry.id)
				{
					found = true;
					wanted = listed_trigger;
				}
			}
		}
		if (found) set_text(&entry.trigger, wanted, b.allocator);
		if (binding)
		{
			entry.state = found ? BOUND : REFUSED;
			if (!found) set_text(&entry.trigger, "", b.allocator);
		}
	}
}

// The id and trigger text of one `(sa{sv})` entry. False when the entry does not have that shape.
fn bool read_entry(Value entry, String* id, String* trigger) @local
{
	if (try name = entry.at(0))
	{
		if (try text = name.as_string())
		{
			*id = text;
			*trigger = "";
			if (try props = entry.at(1))
			{
				if (try description = props.dict_get("trigger_description"))
				{
					if (try value = description.as_string()) *trigger = value;
				}
			}
			return true;
		}
	}
	return false;
}

// Activated: a shortcut was pressed in our session.
fn void on_activated(void* context, Message* signal)
{
	emit_press(context, signal, EventKind.PRESSED);
}

// Deactivated: a shortcut was released in our session.
fn void on_deactivated(void* context, Message* signal)
{
	emit_press(context, signal, EventKind.RELEASED);
}

// ShortcutsChanged: the portal changed the triggers it shows; take the new ones.
fn void on_shortcuts_changed(void* context, Message* signal)
{
	Backend* b = (Backend*)context;
	if (b.session.len == 0) return;
	@pool()
	{
		if (catch err = read_changed(b, signal))
		{
			// A malformed signal changes nothing we can read; the next round reads the state again.
		}
	};
}

fn void? read_changed(Backend* b, Message* signal) @local
{
	marshal::Reader reader = signal.reader()!;
	String session = reader.read_object_path()!;
	if (session != b.session) return;
	Value list = reader.read_value(tmem)!;
	apply_shortcuts(b, list, false);
}

// Activated and Deactivated share one layout: session, shortcut id, timestamp (ms), options.
fn void emit_press(void* context, Message* signal, EventKind kind) @local
{
	Backend* b = (Backend*)context;
	if (b.session.len == 0) return;
	@pool()
	{
		if (catch err = read_press(b, signal, kind))
		{
			// Not for us (another session) or malformed: nothing to report.
		}
	};
}

fn void? read_press(Backend* b, Message* signal, EventKind kind) @local
{
	marshal::Reader reader = signal.reader()!;
	String session = reader.read_object_path()!;
	if (session != b.session) return;
	String id = reader.read_string()!;
	ulong timestamp = reader.read_u64()!;
	Value options = reader.read_value(tmem)!;
	String token = "";
	if (try handle = options.dict_get("activation_token"))
	{
		if (try text = handle.as_string()) token = text;
	}
	Snapshot{Event}* packet = b.hub.emit_begin();
	Allocator arena = packet.allocator();
	packet.value = {
		.kind = kind,
		.id = dup(id, arena),
		.at = clock::now(),
		.platform_time = maybe::value(timestamp),
		.activation_token = dup(token, arena),
	};
	b.hub.emit(packet);
}
