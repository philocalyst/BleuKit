<*
 The MPRIS backend: Linux players on the D-Bus session bus.

 Opened on a trial connection first, so a missing bus is reported by `open`
 instead of an idle worker. The worker then opens its own connection, because a
 connection belongs to the thread that opened it.

 Not available here: MPRIS export (publishing our own session, cut in v1), the
 2.3 `GetArtworkFd` (art bytes), `TrackList` and `Playlists`.
*>
module bleu::media::mpris @feat(LINUX);
import std::io::path, std::time, std::os::env, bleu::availability, bleu::dbus::connection, bleu::error, bleu::media, bleu::media::mpris_convert, bleu::rt::poller, bleu::rt::worker, bleu::service;

<* Commands taken from the mailbox per pass of the loop. *>
const usz COMMAND_BATCH = 16;

<* Poller tag of the bus connection's socket. *>
const usz CONNECTION_TAG = 1;

struct Backend
{
	Allocator allocator;
	String address; // "" for the session bus
	Duration refresh;
}

const Driver DRIVER = {
	.info = { "mpris", "MPRIS2 players on the D-Bus session bus", 10 },
	.id = MPRIS,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

<*
 MPRIS needs a session bus. Its address is in the environment, or the bus
 socket sits in XDG_RUNTIME_DIR, where the default address points.
*>
fn bool probe(Options* options)
{
	if (options.bus_address.len > 0) return true;
	@pool()
	{
		if (try env::get_var(tmem, "DBUS_SESSION_BUS_ADDRESS")) return true;
		if (try runtime = env::get_var(tmem, "XDG_RUNTIME_DIR")) return path::is_dir((Path)runtime);
	};
	return false;
}

<* Check that the bus answers now, and fill the capabilities. *>
fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	fill_capabilities(capabilities);
	Connection trial;
	trial.init(allocator);
	defer trial.free();
	if (options.bus_address.len > 0)
	{
		trial.open_address(options.bus_address)!;
	}
	else
	{
		trial.open_session()!;
	}
	Backend* backend = alloc::new(allocator, Backend, { .refresh = options.refresh });
	backend.address = mpris_convert::copy_text(options.bus_address, allocator);
	return backend;
}

// What this backend can do, and why the rest is not offered.
fn void fill_capabilities(Capabilities* capabilities) @private
{
	capabilities.init(availability::YES);
	capabilities.values[PUBLISH_SESSION.ordinal] = availability::no(
		UNSUPPORTED_BACKEND,
		"Publishing our own session is not in v1 (MPRIS export is cut)"
	);
	capabilities.values[NOW_PLAYING_PRIVATE.ordinal] = availability::no(
		UNSUPPORTED_OS,
		"MPRIS is the only player interface on Linux"
	);
}

fn void destroy(Allocator allocator, void* state)
{
	Backend* backend = (Backend*)state;
	if (backend.address.len > 0) alloc::free(allocator, backend.address.ptr);
	alloc::free(allocator, backend);
}

<*
 The worker's loop: wait for the bus, the mailbox or the position tick; dispatch
 what the bus sent; run the commands; re-read what changed; publish.
*>
fn void run(void* state, MediaHub* hub, Host{Command}* host)
{
	Backend* backend = (Backend*)state;
	Session session;
	if (catch err = session.open(backend.allocator, backend.address, backend.refresh)) return;
	defer session.close();
	if (catch err = session.reconcile()) session.absorb(err);

	Poller poller;
	if (catch err = poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	int fd = session.connection.fd() ?? -1;
	if (fd < 0) return;
	Interest readable;
	readable.readable = true;
	if (catch err = poller.add({ .handle = (Native)fd, .interest = readable, .tag = CONNECTION_TAG })) return;

	Command[COMMAND_BATCH] commands;
	session.publish(hub);
	while (!host.stopping() && !session.disconnected)
	{
		Duration timeout = session.wait_time();
		session.busy = false;
		if (catch err = poller.wait(timeout))
		{
			if (err != TIMEOUT) break;
		}
		if (catch err = session.connection.process())
		{
			session.absorb(err);
			session.disconnected = true;
		}
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++) session.execute(&commands[i]);
		if (session.roster_dirty)
		{
			if (catch err = session.reconcile()) session.absorb(err);
		}
		session.refresh_dirty();
		session.tick();
		session.publish(hub);
	}
	session.forget_all();
	session.publish(hub);
}
