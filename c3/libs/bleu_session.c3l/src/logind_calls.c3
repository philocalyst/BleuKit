<*
 Carrying out the requests of `Session`: lock, unlock, lock another session, terminate a
 session. Each is one method call on the logind Manager; the state change itself arrives later,
 as a PropertiesChanged signal, and the next snapshot shows it.

 Sources: org.freedesktop.login1 Manager methods LockSession(s), UnlockSession(s) and
 TerminateSession(s) (manual page org.freedesktop.login1(5)).
*>
module bleu::session::logind @feat(LINUX);
import bleu::dbus::message, bleu::error, bleu::session;

<*
 Run the command if it is a request. Idle watches never reach this backend: `Session` refuses
 them first, because logind does not measure idle time.
*>
fn void execute(Logind* b, Command* command)
{
	if (command.kind != CommandKind.REQUEST) return;
	SessionOperation* operation = command.operation;
	if (catch err = call_request(b, command.request, command.session))
	{
		operation.fail(err);
	}
	else
	{
		operation.succeed(command.request);
	}
	operation.release();
	b.dirty = true;
}

<* The method call for `request`. `session_id` names the target of LOCK_SESSION and TERMINATE_SESSION. *>
fn void? call_request(Logind* b, Request request, String session_id)
{
	switch (request)
	{
		case Request.LOCK: return call_manager(b, "LockSession", current_session(b)!);
		case Request.UNLOCK: return call_manager(b, "UnlockSession", current_session(b)!);
		case Request.LOCK_SESSION: return call_manager(b, "LockSession", session_id);
		case Request.TERMINATE_SESSION: return call_manager(b, "TerminateSession", session_id);
	}
}

<* The id of this process's session. UNAVAILABLE when it is not in one. *>
fn String? current_session(Logind* b)
{
	if (!b.has_session) return error::raise(
		error::UNAVAILABLE,
		error::Domain.INTERNAL,
		0,
		"this process is not in a logind session"
	)~;
	return b.session_id;
}

<* One Manager method that takes a session id and returns nothing. *>
fn void? call_manager(Logind* b, String member, String session_id)
{
	Message* call = b.manager.new_call(b.allocator, member)!;
	defer call.release();
	call.body_writer("s")!.append_string(session_id)!;
	Message* reply = b.bus.call(call)!;
	reply.release();
}