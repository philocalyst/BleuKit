<*
 Answering incoming method calls: `Call`, the handler's view of one call, and
 the replies that answer it, now or later through a `ReplyToken`.

 A call is answered exactly once. A handler either replies (`reply`,
 `reply_error`), returns a fault that becomes the D-Bus error `error_name_for`
 gives it, or defers the reply (`defer_reply`) and answers later. A reply to a
 call sent with NO_REPLY_EXPECTED is not sent at all.
*>
module bleu::dbus::server;
import bleu::error, bleu::dbus::message, bleu::dbus::marshal, bleu::dbus::value, bleu::dbus::names;

<*
 One incoming method call, as a handler sees it. The strings are valid until the
 handler returns; copy what must outlive it, or defer the reply.
*>
struct Call
{
	ObjectServer* server;
	Message* message;
	String path;
	String interface_name;
	String member;
	String sender;
	uint serial;
	String out_signature;
	bool expects_reply;
	bool answered;
}

<*
 A reader over the arguments, positioned at the first one.

 @return? error::PROTOCOL : "The body does not match the signature it was received with"
*>
fn Reader? Call.reader(&self) => self.message.reader();

<*
 Answer the call with `values`, which must follow the method's out-signature.
 `fds[i]` is the descriptor for the UNIX_FD value whose index is `i`; the
 descriptors must stay open until the reply is sent.

 If the values do not match the out-signature, the caller gets
 `org.freedesktop.DBus.Error.Failed` instead, and the mismatch is returned.

 @return? error::INVALID_STATE : "The call has already been answered"
 @return? error::INVALID_ARGUMENT : "The values do not match the out-signature"
*>
fn void? Call.reply(&self, Value[] values, int[] fds = { })
{
	if (self.answered) return error::INVALID_STATE~;
	self.answered = true;
	if (!self.expects_reply) return;
	return send_return_to(self.server, self.sender, self.serial, self.out_signature, values, fds);
}

<*
 Answer the call with the D-Bus error `name`, and a human-readable `text`. Use
 it for an error that has a name of its own; a fault returned by the handler is
 named by `error_name_for`.

 @return? error::INVALID_ARGUMENT : "The error name is not valid"
 @return? error::INVALID_STATE : "The call has already been answered"
*>
fn void? Call.reply_error(&self, String name, String text)
{
	if (!names::is_error_name(name)) return error::INVALID_ARGUMENT~;
	if (self.answered) return error::INVALID_STATE~;
	self.answered = true;
	if (!self.expects_reply) return;
	return send_error_reply(self.server, self.sender, self.serial, name, text);
}

<*
 Keep the call open. The handler returns without answering, and the reply is
 sent later with `ObjectServer.reply` or `ObjectServer.reply_error`, using the
 token returned here. The token is used once.

 @return? error::INVALID_STATE : "The call has already been answered"
*>
fn ReplyToken? Call.defer_reply(&self)
{
	if (self.answered) return error::INVALID_STATE~;
	self.answered = true;
	return park(self.server, self.sender, self.serial, self.out_signature, self.expects_reply);
}

<*
 Answer a deferred call with `values`, which must follow its out-signature (see
 `Call.reply`). The token is used up: a second answer to it is refused.

 @param values : "The results, in order"
 @param fds : "The descriptors of the UNIX_FD values, by index"
 @return? NOT_FOUND : "No deferred call has this token"
 @return? error::INVALID_ARGUMENT : "The values do not match the out-signature"
*>
fn void? ObjectServer.reply(&self, ReplyToken token, Value[] values, int[] fds = { })
{
	Deferred* d = self.take(token)!;
	defer free_deferred(self, d);
	if (!d.expects_reply) return;
	return send_return_to(self, d.destination.str_view(), d.serial, d.out_signature.str_view(), values, fds);
}

<*
 Answer a deferred call with the D-Bus error `name`. The token is used up.

 @return? NOT_FOUND : "No deferred call has this token"
 @return? error::INVALID_ARGUMENT : "The error name is not valid"
*>
fn void? ObjectServer.reply_error(&self, ReplyToken token, String name, String text)
{
	if (!names::is_error_name(name)) return error::INVALID_ARGUMENT~;
	Deferred* d = self.take(token)!;
	defer free_deferred(self, d);
	if (!d.expects_reply) return;
	return send_error_reply(self, d.destination.str_view(), d.serial, name, text);
}

// Records a reply that will be sent later, and returns its token.
fn ReplyToken park(
	ObjectServer* server,
	String destination,
	uint serial,
	String out_signature,
	bool expects_reply
) @private
{
	Deferred* d = alloc::new(server.allocator, Deferred);
	uint token  = server.next_token++;
	// Zero means "no token", so it is skipped when the counter wraps.
	if (token == 0) token = server.next_token++;
	*d = { .token = (ReplyToken)token, .serial = serial, .expects_reply = expects_reply };
	d.destination.init(server.allocator);
	d.destination.append_string(destination);
	d.out_signature.init(server.allocator);
	d.out_signature.append_string(out_signature);
	server.deferred.push(d);
	return (ReplyToken)token;
}

// The deferred reply with `token`, removed from the list. The caller frees it.
fn Deferred*? ObjectServer.take(&self, ReplyToken token)
{
	for (sz k = 0; k < (sz)self.deferred.len(); k++)
	{
		Deferred* d = self.deferred.get(k);
		if (d.token != token) continue;
		self.deferred.remove_at(k);
		return d;
	}
	return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no deferred call has token %d", token)~;
}

// Builds a METHOD_RETURN with `values` and `fds` and sends it. A body that does not
// match `out_signature` is replaced by a Failed error, and the mismatch is returned.
fn void? send_return_to(
	ObjectServer* server,
	String destination,
	uint serial,
	String out_signature,
	Value[] values,
	int[] fds
) @private
{
	Message* m = message::reply_to(server.allocator, destination, serial)!;
	defer m.release();
	if (catch err = fill_body(m, out_signature, values, fds))
	{
		// If this send fails too, the connection is gone; the mismatch is what the handler needs to see.
		if (catch send_error_reply(server, destination, serial, ERROR_FAILED, "the reply does not match its signature"))
		{
		}
		return err~;
	}
	return send_message(server, m);
}

// Writes `values` as the body of `m`, for `signature`, and attaches the descriptors in index order.
fn void? fill_body(Message* m, String signature, Value[] values, int[] fds) @private
{
	Writer* w = m.body_writer(signature)!;
	foreach (v : values) w.append_value(v)!;
	w.finish()!;
	foreach (fd : fds) m.attach_fd(fd);
}

// Builds an ERROR reply and sends it.
fn void? send_error_reply(ObjectServer* server, String destination, uint serial, String name, String text) @private
{
	Message* m = message::error_reply_to(server.allocator, destination, serial, name, text)!;
	defer m.release();
	return send_message(server, m);
}

// Hands a built message to the sink.
fn void? send_message(ObjectServer* server, Message* m) @private
{
	if (!server.sink) return error::DISCONNECTED~;
	return server.sink(server.sink_context, m);
}

<*
 The D-Bus error name a fault is answered with. The names are the ones
 `bleu::dbus::errors` reads back, so a service's error round-trips to the same
 class, except for the classes with no name of their own (UNSUPPORTED, OUT_OF_RANGE,
 CANCELLED and the rest), which are answered with the general names below.

 @param failure : "The fault a handler returned"
*>
fn String error_name_for(fault failure)
{
	switch (failure)
	{
		case error::UNAVAILABLE: return "org.freedesktop.DBus.Error.ServiceUnknown";
		case error::PERMISSION_DENIED: return "org.freedesktop.DBus.Error.AccessDenied";
		case error::AUTH_REQUIRED: return "org.freedesktop.DBus.Error.InteractiveAuthorizationRequired";
		case NOT_FOUND: return ERROR_UNKNOWN_OBJECT;
		case error::INVALID_ARGUMENT: return ERROR_INVALID_ARGS;
		case error::OUT_OF_RANGE: return ERROR_INVALID_ARGS;
		case TIMEOUT: return "org.freedesktop.DBus.Error.Timeout";
		case error::DISCONNECTED: return "org.freedesktop.DBus.Error.Disconnected";
		case error::NO_MEMORY: return "org.freedesktop.DBus.Error.NoMemory";
		case error::UNSUPPORTED: return "org.freedesktop.DBus.Error.NotSupported";
		default: return ERROR_FAILED;
	}
}

// The text of the reply for a fault: the message recorded with it when the record is for this fault.
fn String detail_text(fault failure) @private
{
	Detail* d = error::last();
	if (d.status == error::status_of(failure)) return d.message();
	return string::tformat("%s", failure);
}