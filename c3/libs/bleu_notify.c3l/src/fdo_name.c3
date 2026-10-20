<*
 Taking the freedesktop notification name, and naming whoever holds it when we
 cannot. Only Linux's freedesktop server uses this file.
*>
module bleu::notify::fdo @feat(LINUX);
import std::io, bleu::error, bleu::dbus::bus, bleu::dbus::connection, bleu::dbus::message, bleu::dbus::ownership, bleu::dbus::proxy, bleu::rt::fs, bleu::notify;

const String BUS_SERVICE = "org.freedesktop.DBus";
const String BUS_PATH    = "/org/freedesktop/DBus";
const usz COMM_CAPACITY  = 64; // the kernel keeps 15 characters; the buffer leaves room for a trailing newline

<*
 Ask the bus for the notification name. With `Options.replace` the request takes
 it over from its owner; otherwise it is refused while held, and the refusal says
 who holds it.

 @return? error::UNAVAILABLE : "Another daemon owns the name; the message names it"
 @return? error::PERMISSION_DENIED : "The bus refused the request"
*>
fn OwnedName*? claim_name(Backend* backend, Connection* conn, Session* session)
{
	// Never queue: a queued request would report success while another daemon serves. This centre
	// allows itself to be replaced, so that a later `replace` start can take the name over.
	uint flags = bus::NAME_DO_NOT_QUEUE | bus::NAME_ALLOW_REPLACEMENT;
	if (backend.replace) flags |= bus::NAME_REPLACE_EXISTING;
	OwnedName*? owned = conn.own_name(SERVICE_NAME, flags, &on_acquired, &on_lost, session);
	if (catch err = owned)
	{
		if (err != error::BUSY) return err~;
		@pool()
		{
			String holder = owner_identity(conn);
			return error::raise(
				error::UNAVAILABLE,
				error::Domain.DBUS,
				0,
				"%s is owned by %s; Options.replace takes the name over",
				SERVICE_NAME,
				holder
			)~;
		};
	}
	return owned;
}

// The name is ours: nothing to do. (Acquisition is the request's own answer.)
fn void on_acquired(void* context, String name)
{
}

// Another daemon took the name from us: stop serving at the next round.
fn void on_lost(void* context, String name)
{
	Session* session = (Session*)context;
	session.name_lost = true;
}

// Give the name back. A connection that is already gone has given it back already.
fn void release_name(OwnedName* owned)
{
	if (catch owned.release())
	{
		// The bus did not answer ReleaseName: the name goes with the connection.
	}
}

<*
 "The unique name of the holder and, when the bus says which process that is, the
 pid and its command name". Used only to explain a refusal. The text is temporary
 memory: call it inside a `@pool()`.
*>
fn String owner_identity(Connection* conn)
{
	String owner = conn.get_name_owner(SERVICE_NAME, tmem) ?? "an unknown owner";
	if (try pid = owner_pid(conn, owner))
	{
		char[COMM_CAPACITY] buffer;
		String command = process_name(pid, buffer[..]);
		if (command.len > 0) return string::tformat("%s (pid %d, %s)", owner, pid, command);
		return string::tformat("%s (pid %d)", owner, pid);
	}
	return owner;
}

// The process id behind a unique bus name, from org.freedesktop.DBus.GetConnectionUnixProcessID.
fn uint? owner_pid(Connection* conn, String owner)
{
	Proxy bus_proxy = proxy::for_object(conn, BUS_SERVICE, BUS_PATH, BUS_SERVICE)!;
	Message* call   = bus_proxy.new_call(tmem, "GetConnectionUnixProcessID")!;
	defer call.release();
	call.body_writer("s")!.append_string(owner)!;
	Message* reply = conn.call(call)!;
	defer reply.release();
	return reply.reader()!.read_u32()!;
}

// The command name of a process from /proc, read into `buffer`; empty when it cannot be read.
fn String process_name(uint pid, char[] buffer)
{
	String path = string::tformat("/proc/%d/comm", pid);
	return fs::read_trimmed(path, buffer) ?? "";
}