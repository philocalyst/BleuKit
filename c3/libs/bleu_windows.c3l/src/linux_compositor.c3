<*
 The Linux windows backend: the IPC socket of the running compositor.

 The client comes from `bleu::compositor` (Hyprland, sway, i3, niri). One
 worker thread owns the connection: it waits on a poller that holds the event
 socket and the mailbox's wake-up, applies each event to the compositor model
 in place, and publishes the complete state after every change.

 * `REFRESH_NEEDED` from an event means the model cannot be patched: the worker
 asks the compositor for a new snapshot.
 * When the event socket closes or a read fails, the state is published as
 DISCONNECTED with the reason, the connection is dropped, and the worker
 retries with a doubling wait (`Backoff`). `REFRESH` retries at once.
 * Actions queued while disconnected complete with `DISCONNECTED`, not later.
*>
module bleu::windows::linux_compositor @feat(LINUX);
import std::time, bleu::availability, bleu::deadline, bleu::error, bleu::operation, bleu::observe, bleu::rt::poller, bleu::rt::worker, bleu::compositor, bleu::compositor::backend, bleu::compositor::connect, bleu::windows, bleu::windows::linux_map;

// The poller tag of the compositor's event socket. The wake-up has its own tag.
const usz EVENT_TAG       = 1;
// Sources the poller holds: the wake-up and the event socket, with room to spare.
const usz POLLER_CAPACITY = 4;
// Commands taken from the mailbox per round.
const usz COMMAND_BATCH   = 16;
// Page size of the arenas that hold the compositor model and the detection strings.
const sz ARENA_PAGE       = 4096;

<* Settings and nothing else: the connection itself lives in the worker. *>
struct LinuxBackend
{
	Allocator allocator;
	Duration retry;
	Duration retry_max;
}

const Driver DRIVER = {
	.info = { "compositor", "IPC socket of the running Wayland compositor or tiling window manager", 10 },
	.id = COMPOSITOR,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

fn bool probe(Options* options)
{
	@pool()
	{
		return compositor::detect(tmem).kind != compositor::Kind.NONE;
	};
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	// No compositor protocol in this library carries a minimize request or state.
	capabilities.set(
		Cap.MINIMIZE_WINDOW,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"no compositor IPC in this library minimizes a window (Hyprland, sway, i3 and niri report no minimized state)"
		)
	);
	return alloc::new(
		allocator,
		LinuxBackend,
		{ .allocator = allocator, .retry = options.retry, .retry_max = options.retry_max }
	);
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

// The worker: one connection at a time, one model, one mailbox.
fn void run(void* state, WindowsHub* hub, Host{Command}* host)
{
	LinuxBackend* config = (LinuxBackend*)state;
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), POLLER_CAPACITY))
	{
		// Without a poller nothing can be waited on: report it and stop.
		windows::publish_status(hub, error::last().message());
		return;
	}
	defer poller.free();
	Link link;
	link.init(config.allocator, config.retry, config.retry_max);
	defer link.free();
	Command[COMMAND_BATCH] batch;
	link.attempt(&poller, hub);
	while (!host.stopping())
	{
		Duration timeout       = link.connected ? time::FOREVER : link.retry_at.remaining();
		poller::Ready[]? ready = poller.wait(timeout);
		bool timed_out         = false;
		bool events            = false;
		if (catch err = ready)
		{
			// TIMEOUT is the retry tick; anything else means the poll itself failed.
			timed_out = err == TIMEOUT;
			if (!timed_out) link.lose(&poller, hub, error::last().message());
		}
		else
		{
			foreach (item : ready)
			{
				if (item.tag == EVENT_TAG) events = true;
			}
		}
		bool refresh = timed_out || (!link.connected && link.retry_at.expired());
		usz count    = host.mailbox().take_all(batch[..]);
		for (usz i = 0; i < count; i++)
		{
			Command command = batch[i];
			if (command.kind == CommandKind.REFRESH)
			{
				refresh = true;
				continue;
			}
			link.run_command(&poller, hub, &command);
		}
		if (events && link.connected) link.read(&poller, hub);
		if (refresh)
		{
			if (link.connected)
			{
				link.resync(&poller, hub);
			}
			else
			{
				link.attempt(&poller, hub);
			}
		}
	}
}

// One connection to the compositor, and the model it has produced.
struct Link
{
	Allocator allocator;
	backend::Backend client;
	bool connected;
	DynamicArenaAllocator model_arena;
	compositor::Model model;
	Backoff backoff;
	// When the next reconnect attempt is due. Set when a connection is lost or an attempt fails;
	// wake-ups do not move it, so a steady stream of commands cannot postpone the attempt.
	deadline::Deadline retry_at;
}

fn void Link.init(&self, Allocator allocator, Duration retry, Duration retry_max)
{
	*self = { .allocator = allocator };
	self.backoff.init(retry, retry_max);
	self.model_arena.init(allocator, ARENA_PAGE);
}

// Close the connection and free the model. Runs after the poller is no longer used.
fn void Link.free(&self)
{
	if (self.connected)
	{
		self.connected = false;
		self.client.close();
	}
	self.model_arena.free();
}

// Connect, register the event socket and take the first snapshot. A failure is
// published with its reason and the next retry is scheduled.
fn void Link.attempt(&self, Poller* poller, WindowsHub* hub)
{
	if (catch self.open_client(poller))
	{
		self.lose(poller, hub, error::last().message());
		return;
	}
	self.backoff.reset();
	self.publish(hub);
}

// Open the compositor the environment names. Its detection strings die with the scratch arena.
fn void? Link.open_client(&self, Poller* poller)
{
	DynamicArenaAllocator scratch;
	scratch.init(self.allocator, ARENA_PAGE);
	defer scratch.free();
	Allocator scratch_allocator     = &scratch;
	compositor::Detection detection = compositor::detect(scratch_allocator);
	if (detection.kind == compositor::Kind.NONE)
	{
		return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "%s", detection.reason)~;
	}
	backend::Backend client = connect::open(self.allocator, detection)!;
	poller::Interest reading;
	reading.readable = true;
	if (catch err = poller.add({ .handle = client.event_handle(), .interest = reading, .tag = EVENT_TAG }))
	{
		client.close();
		return err~;
	}
	self.client = client;
	self.connected = true;
	if (catch err = self.take_snapshot())
	{
		self.drop(poller);
		return err~;
	}
}

// Read the compositor's whole state into a fresh model arena.
fn void? Link.take_snapshot(&self)
{
	self.model_arena.free();
	self.model_arena.init(self.allocator, ARENA_PAGE);
	compositor::Model? snapshot = self.client.snapshot(&self.model_arena);
	if (catch err = snapshot) return err~;
	self.model = snapshot;
}

// Ask for a new snapshot after the model could not be patched. A failure drops the connection.
fn void Link.resync(&self, Poller* poller, WindowsHub* hub)
{
	if (catch err = self.take_snapshot())
	{
		self.lose(poller, hub, error::last().message());
		return;
	}
	self.publish(hub);
}

// Apply the events that are waiting, then publish the change or resynchronise.
fn void Link.read(&self, Poller* poller, WindowsHub* hub)
{
	backend::Refresh? outcome = self.client.read_events(&self.model, &self.model_arena);
	if (catch err = outcome)
	{
		self.lose(poller, hub, error::last().message());
		return;
	}
	backend::Refresh refresh = outcome;
	if (refresh == backend::Refresh.REFRESH_NEEDED)
	{
		self.resync(poller, hub);
	}
	else if (refresh == backend::Refresh.UPDATED)
	{
		self.publish(hub);
	}
}

// Run one action. The request is started, completed and released here.
fn void Link.run_command(&self, Poller* poller, WindowsHub* hub, Command* command)
{
	Operation{bool}* request = command.request;
	request.start();
	if (!self.connected)
	{
		request.fail(error::raise(error::DISCONNECTED, error::Domain.INTERNAL, 0, "the compositor is not connected"));
	}
	else if (catch err = self.act(command))
	{
		request.fail(err);
		if (err == error::DISCONNECTED) self.lose(poller, hub, error::last().message());
	}
	else
	{
		request.succeed(true);
	}
	request.release();
}

fn void? Link.act(&self, Command* command)
{
	backend::Backend client = self.client;
	switch (command.kind)
	{
		case CommandKind.REFRESH: return;
		case CommandKind.FOCUS_WINDOW: return client.focus_window(command.target);
		case CommandKind.CLOSE_WINDOW: return client.close_window(command.target);
		case CommandKind.MINIMIZE_WINDOW:
			return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "no compositor minimizes a window")~;
		case CommandKind.SWITCH_WORKSPACE: return client.switch_workspace(command.target);
		case CommandKind.MOVE_WINDOW_TO_WORKSPACE: return client.move_window(command.target, command.destination);
		case CommandKind.TOGGLE_FLOATING: return client.toggle_floating(command.target);
		case CommandKind.TOGGLE_FULLSCREEN: return client.toggle_fullscreen(command.target);
	}
}

// The connection is lost. The reason is copied before the socket is closed, because
// the caller's text lives in the thread's error record, which a failing close or poller
// call overwrites.
fn void Link.lose(&self, Poller* poller, WindowsHub* hub, String reason)
{
	@pool()
	{
		String kept = reason.copy(tmem);
		self.drop(poller);
		self.retry_at = deadline::after(self.backoff.take());
		windows::publish_status(hub, kept);
	};
}

// Forget the connection: remove the event socket from the poller and close the client.
fn void Link.drop(&self, Poller* poller)
{
	if (!self.connected) return;
	self.connected = false;
	// The source may already be gone when the socket failed; there is nothing to undo then.
	if (catch poller.remove(EVENT_TAG))
	{
	}
	self.client.close();
	self.model = { };
}

// Build the connected state from the model and publish whatever differs.
fn void Link.publish(&self, WindowsHub* hub)
{
	Snapshot{State}* next = hub.begin();
	linux_map::fill_state(&next.value, &self.model, next.allocator());
	windows::publish_changes(hub, next);
}