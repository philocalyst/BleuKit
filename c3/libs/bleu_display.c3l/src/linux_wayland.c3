<*
 The Linux backend: a Wayland compositor, read through `wl_output` and `xdg-output`, and changed
 through `wlr-output-management` when the compositor offers it. The worker thread owns the
 connection; the poller wakes it for compositor events and for commands.
*>
module bleu::display::linux_wayland @feat(LINUX);
import bleu::display, bleu::error, bleu::availability, bleu::rt::poller, bleu::rt::worker, bleu::wl, bleu::observe, bleu::operation, std::time, std::time::clock, std::os::env;

// The poller tag of the Wayland socket.
const usz CLIENT_TAG = 1;

const Driver DRIVER = {
	.info = { "wayland", "Wayland compositor (wlr-output-management, or wl_output read-only)", 20 },
	.id = WAYLAND,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// A Wayland session is possible when the environment names a display.
fn bool probe(Options* options)
{
	if (try name = env::tget_var("WAYLAND_DISPLAY")) return name.len > 0;
	return false;
}

// Connect, learn the outputs and the route, and say what the route can do.
fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	wl::Client* client = alloc::new(allocator, wl::Client);
	if (catch err = client.connect_env(allocator))
	{
		alloc::free(allocator, client);
		return error::raise(error::UNAVAILABLE, error::Domain.WAYLAND, 0, "no Wayland display: %s", error::last()
			.message())~;
	}
	Session* session = attach(allocator, client, options.root)!;
	fill_capabilities(session, capabilities);
	return session;
}

fn void destroy(Allocator allocator, void* state)
{
	Session* session = (Session*)state;
	session.close();
}

// Caps of the wlr route are available; the read-only route says so for every change.
fn void fill_capabilities(Session* s, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	if (!s.wlr)
	{
		String note = "the compositor has no wlr-output-management: the layout is read-only";
		capabilities.set(SET_LAYOUT, availability::no(availability::Reason.UNSUPPORTED_BACKEND, note));
		capabilities.set(SET_MODE, availability::no(availability::Reason.UNSUPPORTED_BACKEND, note));
		capabilities.set(SET_SCALE, availability::no(availability::Reason.UNSUPPORTED_BACKEND, note));
		capabilities.set(SET_TRANSFORM, availability::no(availability::Reason.UNSUPPORTED_BACKEND, note));
		capabilities.set(SET_ENABLED, availability::no(availability::Reason.UNSUPPORTED_BACKEND, note));
		capabilities.set(TEST_ONLY, availability::no(availability::Reason.UNSUPPORTED_BACKEND, note));
		capabilities.set(REVERT, availability::no(availability::Reason.UNSUPPORTED_BACKEND, note));
		capabilities.set(PERSISTENT, availability::no(availability::Reason.UNSUPPORTED_BACKEND, note));
		capabilities.set(SET_MIRROR, availability::no(availability::Reason.UNSUPPORTED_BACKEND, note));
		capabilities.set(SET_HDR, availability::no(availability::Reason.UNSUPPORTED_BACKEND, note));
		capabilities.set(SET_COLOUR_DEPTH, availability::no(availability::Reason.UNSUPPORTED_BACKEND, note));
		capabilities.set(SET_ADAPTIVE_SYNC, availability::no(availability::Reason.UNSUPPORTED_BACKEND, note));
		return;
	}
	capabilities.set(
		PERSISTENT,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"the compositor keeps its own layout; wlr-output-management cannot persist it"
		)
	);
	capabilities.set(
		SET_MIRROR,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "wlr-output-management has no mirror field")
	);
	capabilities.set(
		SET_HDR,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "wlr-output-management has no HDR field")
	);
	capabilities.set(
		SET_COLOUR_DEPTH,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "wlr-output-management has no colour depth field")
	);
	capabilities.set(
		SET_ADAPTIVE_SYNC,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"adaptive sync is read from the compositor but not written in this version"
		)
	);
}

<*
 The worker's loop: wait for the socket or a command or a deadline; dispatch events; carry out
 commands; advance the request in flight and the rollback; publish what changed.
*>
fn void run(void* state, display::DisplayHub* hub, Host{Command}* host)
{
	Session* s = (Session*)state;
	s.hub = hub;
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 2)) return;
	defer poller.free();
	if (catch s.client.conn.set_nonblocking(true)) return;
	Source source = { .handle = s.client.native(), .tag = CLIENT_TAG };
	source.interest.readable = true;
	if (catch poller.add(source)) return;
	publish(s);
	Command[8] commands;
	while (!host.stopping())
	{
		if (catch s.client.flush()) break;
		Clock now      = clock::now();
		Ready[]? ready = poller.wait(next_wake(s, now));
		if (catch err = ready)
		{
			// TIMEOUT is the normal end of the wait; any other error means the poller is broken, and the session stops.
			if (err != TIMEOUT) break;
		}
		else if (!dispatch_ready(s, ready)) break;
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++) handle_command(s, commands[i], clock::now());
		advance(s, clock::now());
		if (catch s.client.flush()) break;
		if (s.dirty)
		{
			s.dirty = false;
			publish(s);
		}
	}
	shutdown(s);
}

// Dispatch the socket when it is ready. False when the connection failed: the session must stop.
fn bool dispatch_ready(Session* s, Ready[] ready) @local
{
	foreach (event : ready)
	{
		if (event.tag != CLIENT_TAG) continue;
		if (catch s.client.dispatch()) return false;
	}
	return true;
}

// One command from the mailbox.
fn void handle_command(Session* s, Command command, Clock now)
{
	switch (command.kind)
	{
		case REFRESH: s.dirty = true;
		case CONFIRM: confirm(s, now);
		case APPLY: begin_apply(s, command, now);
	}
}

<*
 Stop. A request still in flight will never be answered, so it fails with DISCONNECTED first; only
 then may a rollback that is still armed take the pending slot. That rollback is sent without
 waiting for its answer, because the connection closes right after it: its outcome is not known
 once the service has stopped (README, "Not done"). Queued commands are failed by the hub.
*>
fn void shutdown(Session* s)
{
	if (s.pending)
	{
		finish_failed(
			s.pending,
			error::raise(error::DISCONNECTED, error::Domain.WAYLAND, 0, "the display service stopped")
		);
	}
	if (s.guard.armed)
	{
		start_revert(s, clock::now());
		if (s.pending) release_pending(s.pending);
	}
	// Best effort: the connection is closing, so a failed flush has nobody left to report it to.
	if (catch s.client.flush())
	{
	}
}