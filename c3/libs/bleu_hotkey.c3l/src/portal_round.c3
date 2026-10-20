<*
 One round of the portal protocol: close the previous session, create a session, list what the portal
 remembers, bind the whole set of registrations, and complete the requests the round served.

 Each step sends one call and waits for its Request.Response. The reply handler and the signal handler
 only record what arrived (`portal_answers.c3`); `advance` moves the round on, on the worker thread.
*>
module bleu::hotkey::portal @feat(LINUX);
import bleu::availability, bleu::dbus::connection, bleu::dbus::match, bleu::dbus::message, bleu::dbus::marshal, bleu::error, bleu::hotkey, bleu::hotkey::portal_path, bleu::operation, bleu::rt::worker;

// One `a{sv}` entry whose value is a string.
struct OptionText
{
	String key;
	String value;
}

// The method each step calls.
fn String method_name(Step step)
{
	switch (step)
	{
		case CREATING: return "CreateSession";
		case LISTING: return "ListShortcuts";
		case BINDING: return "BindShortcuts";
		case IDLE: return "";
	}
}

<*
 Begin a round with the registrations as they are now. A round with nothing to bind only closes the
 previous session and completes the waiting requests.
*>
fn void start_round(Backend* b)
{
	b.dirty = false;
	if (b.session.len > 0) send_close(b);
	hotkey::text_set(&b.session, "", b.allocator);
	if (b.bindings.len() == 0)
	{
		move_waiting(b);
		finish_round(b);
		return;
	}
	if (catch err = start_step(b, CREATING)) abort_round(b, err, "Could not create a shortcut session", REFUSED);
}

// Start `step`: record it, subscribe to the Request it will answer on, and send the call.
fn void? start_step(Backend* b, Step step)
{
	b.step = step;
	b.replied = false;
	b.answered = false;
	b.reply_failed = false;
	b.tokens++;
	@pool()
	{
		String token = portal_path::token(b.tokens, tmem);
		String path  = portal_path::request_path(b.sender, token, tmem)!;
		hotkey::text_set(&b.request, path, b.allocator);
		subscribe_response(b, b.request)!;
		Message* call = message::method_call(
			b.allocator,
			PORTAL_NAME,
			PORTAL_PATH,
			GLOBAL_SHORTCUTS_IFACE,
			method_name(step)
		)!;
		defer call.release();
		fill_call(call, b, step, token)!;
		b.connection.call_async(call, &on_reply, b)!;
	};
}

// Move to `step` and send its call; a failure to send ends the round.
fn void next_step(Backend* b, Step step)
{
	if (step == BINDING)
	{
		// Requests accepted while the session was being made are bound by this round too.
		move_waiting(b);
		b.dirty = false;
	}
	if (catch err = start_step(b, step)) abort_round(b, err, "Could not ask the portal for the next step", REFUSED);
}

<*
 Act on what the handlers recorded since the last call: a Response or a reply, and the
 requests waiting for a round. Called once per worker loop, on the worker thread.
*>
fn void advance(Backend* b)
{
	if (b.step == IDLE)
	{
		if (b.dirty && b.connected && b.registration.ok()) start_round(b);
		return;
	}
	if (b.reply_handle.len > 0) follow_reply_handle(b);
	if (b.reply_failed)
	{
		b.reply_failed = false;
		step_failed(b, b.reply_fault);
		return;
	}
	// The reply and the Response may come in either order: act once both have.
	if (!b.replied || !b.answered) return;
	b.replied = false;
	b.answered = false;
	unsubscribe_response(b);
	if (b.answer_code != RESPONSE_SUCCESS)
	{
		response_failed(b);
		return;
	}
	switch (b.step)
	{
		case CREATING: next_step(b, LISTING);
		case LISTING: next_step(b, BINDING);
		case BINDING: finish_round(b);
		case IDLE: return;
	}
}

// The reply named a different Request object than the one we subscribed to (an older portal does
// this): subscribe to the path it named. A Response sent before that subscription is not seen.
fn void follow_reply_handle(Backend* b)
{
	if (b.reply_handle != b.request)
	{
		hotkey::text_set(&b.request, b.reply_handle, b.allocator);
		if (catch err = subscribe_response(b, b.request))
		{
			hotkey::text_set(&b.reply_handle, "", b.allocator);
			step_failed(b, err);
			return;
		}
	}
	hotkey::text_set(&b.reply_handle, "", b.allocator);
}

// A call of the step failed (the reply was an error): the Response will never come.
fn void step_failed(Backend* b, fault failure)
{
	if (b.step == LISTING)
	{
		// ListShortcuts only tells what the portal remembers: the binding can go on without it.
		next_step(b, BINDING);
		return;
	}
	b.registration = availability::no(
		availability::Reason.BACKEND_STOPPED,
		"The portal did not answer the request; it may have stopped"
	);
	abort_round(b, failure, "The portal did not answer the request", REFUSED);
}

// The Response carried an error code.
fn void response_failed(Backend* b)
{
	if (b.step == LISTING)
	{
		next_step(b, BINDING);
		return;
	}
	if (b.answer_code == RESPONSE_CANCELLED)
	{
		abort_round(b, error::CANCELLED, "The user declined the shortcut dialog", REFUSED);
		return;
	}
	// Response 2 is how a portal answers when its desktop cannot do the request: the registration says so.
	b.registration = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"The portal ended the request with response 2: this desktop does not bind global shortcuts"
	);
	abort_round(b, error::UNAVAILABLE, "The portal ended the shortcut request", REFUSED);
}

// Complete the round's requests with their binding, and end it.
fn void finish_round(Backend* b)
{
	while (try waiting = b.in_round.pop_first()) complete_waiting(b, &waiting);
	end_step(b);
}

// Complete the round's requests with `failure`, and set every registration to `state`. A lost
// connection (PENDING) keeps the shortcuts the user asked for and binds them again later; the ones
// that never got bound are dropped, since their callers were told they failed.
fn void abort_round(Backend* b, fault failure, String text, BindingState state)
{
	move_waiting(b);
	while (try waiting = b.in_round.pop_first())
	{
		if (waiting.removal) free_binding(b.allocator, &waiting.removed);
		fail_waiting(b, &waiting, failure, text);
	}
	settle_bindings(b, state);
	b.dirty = false;
	end_step(b);
}

fn void end_step(Backend* b)
{
	b.step = IDLE;
	b.replied = false;
	b.answered = false;
	b.reply_failed = false;
	hotkey::text_set(&b.reply_handle, "", b.allocator);
	unsubscribe_response(b);
}

// Make the registrations reflect a round that did not finish.
fn void settle_bindings(Backend* b, BindingState state)
{
	for (sz i = (sz)b.bindings.len() - 1; i >= 0; i--)
	{
		Binding* binding = b.bindings.get_ref(i);
		if (state == PENDING && binding.state == PENDING)
		{
			free_binding(b.allocator, binding);
			b.bindings.remove_at(i);
			continue;
		}
		binding.state = state;
		hotkey::text_set(&binding.trigger, "", b.allocator);
	}
}

// Every waiting request joins the round that starts next.
fn void move_waiting(Backend* b)
{
	while (try waiting = b.waiting.pop_first()) b.in_round.push(waiting);
}

// Complete one request of a finished round.
fn void complete_waiting(Backend* b, Waiting* waiting)
{
	Task* op = waiting.operation;
	if (waiting.removal)
	{
		Binding value = copy_binding(waiting.removed, op.allocator());
		free_binding(b.allocator, &waiting.removed);
		(void)op.succeed(value);
	}
	else
	{
		sz index = find_index(b, waiting.id);
		if (index >= 0)
		{
			(void)op.succeed(copy_binding(b.bindings.get(index), op.allocator()));
		}
		else
		{
			fail_waiting_op(op, NOT_FOUND, "The shortcut was removed before the portal bound it");
		}
	}
	hotkey::text_free(waiting.id, b.allocator);
	op.release();
}

// Fail one request of an aborted round (its removal, if any, was freed by the caller).
fn void fail_waiting(Backend* b, Waiting* waiting, fault failure, String text)
{
	fail_waiting_op(waiting.operation, failure, text);
	hotkey::text_free(waiting.id, b.allocator);
	waiting.operation.release();
}

fn void fail_waiting_op(Task* op, fault failure, String text)
{
	(void)op.fail(error::raise(failure, error::Domain.INTERNAL, 0, "%s", text));
}

// Fill the body of `call` for `step`.
fn void? fill_call(Message* call, Backend* b, Step step, String token)
{
	switch (step)
	{
		case CREATING: return fill_create(call, token);
		case LISTING: return fill_list(call, b.session, token);
		case BINDING: return fill_bind(call, b, token);
		case IDLE: return error::INVALID_STATE~;
	}
}

// CreateSession: the handle token and the session handle token, which name the two object paths.
fn void? fill_create(Message* call, String token) @local
{
	Writer* w             = call.body_writer("a{sv}")!;
	OptionText[2] options = { { "handle_token", token }, { "session_handle_token", token } };
	write_options(w, options[..])!;
}

// ListShortcuts(session, options).
fn void? fill_list(Message* call, String session, String token) @local
{
	Writer* w = call.body_writer("oa{sv}")!;
	w.append_object_path(session)!;
	OptionText[1] options = { { "handle_token", token } };
	write_options(w, options[..])!;
}

// BindShortcuts(session, shortcuts, parent_window "", options).
fn void? fill_bind(Message* call, Backend* b, String token) @local
{
	Writer* w = call.body_writer("oa(sa{sv})sa{sv}")!;
	w.append_object_path(b.session)!;
	write_shortcuts(w, b)!;
	w.append_string("")!;
	OptionText[1] options = { { "handle_token", token } };
	write_options(w, options[..])!;
}

// An `a{sv}` of string values.
fn void? write_options(Writer* w, OptionText[] items) @local
{
	w.begin_array("a{sv}")!;
	foreach (item : items)
	{
		w.begin_dict_entry()!;
		w.append_string(item.key)!;
		w.begin_variant("s")!;
		w.append_string(item.value)!;
		w.end_variant()!;
		w.end_dict_entry()!;
	}
	w.end_array()!;
}

// The `a(sa{sv})` of BindShortcuts: each registration's id, description and preferred trigger.
fn void? write_shortcuts(Writer* w, Backend* b) @local
{
	w.begin_array("a(sa{sv})")!;
	for (sz i = 0; i < b.bindings.len(); i++)
	{
		Binding binding = b.bindings.get(i);
		@pool()
		{
			String trigger      = hotkey::format_portal_trigger(binding.chord, tmem);
			OptionText[2] props = { { "description", binding.description }, { "preferred_trigger", trigger } };
			w.begin_struct()!;
			w.append_string(binding.id)!;
			write_options(w, props[..])!;
			w.end_struct()!;
		};
	}
	w.end_array()!;
}

// Ask the portal to forget the previous session. Nothing waits for the answer.
fn void send_close(Backend* b)
{
	@pool()
	{
		Message* call = message::method_call(b.allocator, PORTAL_NAME, b.session, SESSION_IFACE, "Close") ?? null;
		if (call == null) return;
		defer call.release();
		if (catch b.connection.call_async(call, &ignore_reply, b))
		{
			// The bus is gone: the session goes with it.
		}
	};
}

<* Subscribe to the Response of the Request object at `path`. *>
fn void? subscribe_response(Backend* b, String path)
{
	unsubscribe_response(b);
	match::Match rule;
	rule.init(b.allocator);
	rule.with_type(message::MessageType.SIGNAL)!!;
	rule.with_sender(PORTAL_NAME)!!;
	rule.with_interface(REQUEST_IFACE)!!;
	rule.with_member("Response")!!;
	rule.with_path(path)!!;
	b.response_subscription = b.connection.subscribe(rule, &on_response, b)!;
	b.response_subscribed = true;
}

// Drop the Response subscription, if there is one. Never called from inside a handler.
fn void unsubscribe_response(Backend* b)
{
	if (!b.response_subscribed) return;
	b.response_subscribed = false;
	if (catch b.connection.unsubscribe(b.response_subscription))
	{
		// The connection is gone, and with it the subscription.
	}
}