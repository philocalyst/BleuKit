<* The `session` entry of the registry: open adapter, commands and `Spec`. *>
module bleu::registry::svc_session;
import bleu::session, bleu::registry, bleu::registry::live, bleu::json, bleu::registry::tap;

<* Open the session service with its default backend. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	session::Session* service = session::open(allocator)!;
	return (void*)service;
}

<* `session.lock`: lock the current session. *>
fn void? lock(registry::Request* request)
{
	session::Session* service            = (session::Session*)request.handle;
	session::SessionOperation* operation = service.lock()!;
	defer operation.release();
	session::Request done = registry::await{session::Request}(operation, request.timeout)!;
	return registry::write_value(request.out, "request", done);
}

<* `session.unlock`: unlock the current session. *>
fn void? unlock(registry::Request* request)
{
	session::Session* service            = (session::Session*)request.handle;
	session::SessionOperation* operation = service.unlock()!;
	defer operation.release();
	session::Request done = registry::await{session::Request}(operation, request.timeout)!;
	return registry::write_value(request.out, "request", done);
}

const registry::Command[2] COMMANDS = {
	{ .name = "session.lock", .summary = "Lock the current session.", .run = &lock },
	{ .name = "session.unlock", .summary = "Unlock the current session.", .run = &unlock },
};

const registry::Spec SESSION = {
	.name = "session",
	.summary = "Login session, lock state, idle and sleep (logind, macOS, Windows)",
	.open = &open,
	.close = &live::close{session::Session, session::State, session::Cap},
	.state = &live::state{session::Session, session::State, session::Cap},
	.capabilities = &live::capabilities{session::Session, session::State, session::Cap},
	.backend = &live::backend{session::Session, session::State, session::Cap},
	.watch = &tap::watch{session::Session, session::State},
	.commands = COMMANDS[..],
};