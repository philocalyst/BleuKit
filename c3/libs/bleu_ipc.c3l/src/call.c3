<*
 Handlers, deferred replies and the exactly-once rule.

 Every request gets one reply. The reply is sent by whichever of these comes
 first and only once: `Call.respond_*`, a `Deferred` completion, or, when a
 handler returns without either, an error the dispatcher sends. A second attempt
 is refused with INVALID_STATE and sends nothing.

 The state behind a request is a `Pending`, reference-counted: the dispatch
 holds one reference until the handler returns, and a `Deferred` holds one until
 it completes. The last release frees it.
*>
module bleu::ipc @feat(POSIX);
import std::atomic, bleu::error, bleu::ipc::wire, std::collections::object;

<* The shared state of one request. See the module documentation. *>
struct Pending
{
	Allocator allocator;
	Atomic{int} refs;
	// Set by the one reply. Once set, no reply is sent again.
	Atomic{bool} answered;
	// True while a Deferred holds a reference. Cleared by whichever Deferred completes.
	Atomic{bool} deferred_hold;
	// Handler thread only: `defer()` was taken, so the request stays open after the handler returns.
	bool deferred;
	Server* server;
	usz conn_id;
	long request_id;
}

// A new request state holding the dispatch's reference.
fn Pending* new_pending(Allocator allocator, Server* server, usz conn_id, long request_id) @private
{
	Pending* pending = alloc::new(allocator, Pending);
	pending.allocator = allocator;
	pending.refs.store(1);
	pending.answered.store(false);
	pending.deferred_hold.store(false);
	pending.deferred = false;
	pending.server = server;
	pending.conn_id = conn_id;
	pending.request_id = request_id;
	return pending;
}

// Drop one reference; the last one frees the state.
fn void Pending.release(&self)
{
	if (self.refs.sub(1) != 1) return;
	alloc::free(self.allocator, self);
}

// Send the one reply of a request: a result (a JSON value) or an error (a message).
fn void? reply_to(Pending* pending, String payload, bool as_error) @private
{
	bool expected = false;
	if (!pending.answered.compare_exchange(&expected, true))
	{
		return error::raise(
			error::INVALID_STATE,
			error::Domain.INTERNAL,
			0,
			"request %d was already answered",
			pending.request_id
		)~;
	}
	if (as_error)
	{
		return pending.server.post_reply(
			pending.conn_id,
			wire::error_frame(pending.allocator, pending.request_id, payload)
		);
	}
	if (!wire::is_single_line(payload))
	{
		// The client must still get an answer: an error reply in place of the bad result.
		if (catch pending.server.post_reply(
			pending.conn_id,
			wire::error_frame(pending.allocator, pending.request_id, "result is empty or spans lines")
		))
		{
		}
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"result must be one non-empty line of JSON"
		)~;
	}
	return pending.server.post_reply(
		pending.conn_id,
		wire::result_frame(pending.allocator, pending.request_id, payload)
	);
}

// Give up the reference a Deferred holds, once: the first completion clears the flag.
fn void release_hold(Pending* pending) @private
{
	bool held = true;
	if (pending.deferred_hold.compare_exchange(&held, false)) pending.release();
}

<*
 What a handler receives for one request. `method`, `params` and `id` are the
 request's own: `method` and `params` are borrowed, valid until the handler
 returns, and `params` is never null (a missing or null `params` is an empty
 object). Copy what must outlive the handler, or take a `Deferred`.
*>
struct Call
{
	String method;
	Object* params;
	long id;
	Pending* pending;
}

<*
 Answer the request with a JSON value. The first answer wins.

 @param json_fragment : "One JSON value on one line, written as it is"
 @return? error::INVALID_STATE : "The request was already answered; nothing is sent"
 @return? error::INVALID_ARGUMENT : "The value is empty or spans lines; an error reply is sent instead"
 @return? error::UNAVAILABLE, error::BUSY : "The reply could not be queued: the server is stopped or overloaded"
*>
fn void? Call.respond_raw(&self, String json_fragment) @maydiscard
{
	return reply_to(self.pending, json_fragment, false);
}

<*
 Answer the request with an error message, which is escaped.

 @return? error::INVALID_STATE : "The request was already answered; nothing is sent"
 @return? error::UNAVAILABLE, error::BUSY : "The reply could not be queued"
*>
fn void? Call.respond_error(&self, String message) @maydiscard
{
	return reply_to(self.pending, message, true);
}

<*
 Keep the request open after the handler returns, and answer it later from any
 thread with the returned `Deferred`. Call it on the handler thread, before the
 handler returns. Only one Deferred can be taken per request; a second call, or a
 call after the request was answered, returns a Deferred that refuses to complete.

 The Deferred must be completed, or the request is never closed: the client then
 waits for its own timeout, and the request's small state is leaked.
*>
fn Deferred Call.defer_reply(&self)
{
	Pending* pending = self.pending;
	if (pending.deferred || pending.answered.load()) return { .pending = null };
	pending.deferred = true;
	pending.deferred_hold.store(true);
	pending.refs.add(1);
	return { .pending = pending };
}

<*
 A reply owed to a client after its handler has returned. Completing it is
 allowed from any thread. Completing a copy of an already completed Deferred is
 refused with INVALID_STATE, and sends nothing.
*>
struct Deferred
{
	Pending* pending;
}

<*
 Answer the deferred request with a JSON value. See `Call.respond_raw`.

 @return? error::INVALID_STATE : "The request was already answered or the Deferred is empty"
*>
fn void? Deferred.respond_raw(self, String json_fragment) @maydiscard
{
	if (self.pending == null) return error::raise(
		error::INVALID_STATE,
		error::Domain.INTERNAL,
		0,
		"deferred request is already answered"
	)~;
	defer release_hold(self.pending);
	return reply_to(self.pending, json_fragment, false);
}

<*
 Answer the deferred request with an error message. See `Call.respond_error`.

 @return? error::INVALID_STATE : "The request was already answered or the Deferred is empty"
*>
fn void? Deferred.respond_error(self, String message) @maydiscard
{
	if (self.pending == null) return error::raise(
		error::INVALID_STATE,
		error::Domain.INTERNAL,
		0,
		"deferred request is already answered"
	)~;
	defer release_hold(self.pending);
	return reply_to(self.pending, message, true);
}