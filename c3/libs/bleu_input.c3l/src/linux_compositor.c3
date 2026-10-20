<*
 The Linux compositor backend: the IPC of Hyprland, sway and niri, through `bleu_compositor`.

 Preferred (priority 20). `compositor::detect` names the running compositor from its environment and
 `connect::open` opens its event socket on the worker thread. The poller waits on that socket and on the
 wake-up. Each wake reads the waiting events into the model in place; an event that does not carry the
 change (`REFRESH_NEEDED`) makes the backend take the whole model again. The socket state and the model
 live in arenas of their own; the model's arena is reset each time the model is taken again. A lost socket
 is reconnected on a later poll tick, and until then the state is empty.

 i3 is not offered: its IPC has no keyboard layout list. Hyprland's client reports only the active layout's
 name, so its list is that one entry, and switching is refused with `UNSUPPORTED_BACKEND`: no layout index
 is known to pass to `switchxkblayout`.
*>
module bleu::input::linux_compositor @feat(LINUX);
import std::collections::maybe, bleu::availability, bleu::compositor, bleu::compositor::backend, bleu::compositor::connect, bleu::error, bleu::input, bleu::input::names, bleu::observe, bleu::operation, bleu::rt::poller, bleu::rt::worker, bleu::service;

// The poller tag of the compositor's event socket. The wake-up is not tagged (see bleu_rt).
const usz EVENT_TAG = 1;
// Bytes per page of the arenas that hold the socket state and the model.
const usz ARENA_PAGE = 65536;
// Commands the worker takes in one pass.
const usz COMMAND_BATCH = 8;

<* The backend's state: its poll interval, the compositor it was created for. *>
struct CompositorBackend
{
	Allocator allocator;
	Duration poll;
	compositor::Kind kind;
}

<* One connection to the compositor and the model read over it. *>
struct Session
{
	backend::Backend client;
	bool connected;
	compositor::Model model;
}

const Driver DRIVER = {
	.info = { "compositor", "the running compositor's IPC: Hyprland, sway or niri (bleu_compositor)", 20 },
	.id = Backend.COMPOSITOR,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

<* The compositor `detect` names for this process. Only its kind is kept; the socket paths are dropped. *>
fn compositor::Kind detected_kind() @private
{
	compositor::Kind kind = compositor::Kind.NONE;
	@pool()
	{
		kind = compositor::detect(tmem).kind;
	};
	return kind;
}

<* Whether a compositor this backend can read runs here: Hyprland, sway or niri. *>
fn bool probe(Options* options)
{
	compositor::Kind kind = detected_kind();
	return kind == compositor::Kind.HYPRLAND || kind == compositor::Kind.SWAY || kind == compositor::Kind.NIRI;
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	compositor::Kind kind = detected_kind();
	capabilities.init(availability::YES);
	if (kind == compositor::Kind.HYPRLAND)
	{
		capabilities.set(
			Cap.LIST,
			availability::no(
				availability::Reason.DEGRADED,
				"Hyprland's IPC names only the active layout, so the list has that one entry"
			)
		);
		capabilities.set(
			Cap.SWITCH,
			availability::no(
				availability::Reason.UNSUPPORTED_BACKEND,
				"Hyprland's IPC does not list the layouts, so no layout index can be chosen"
			)
		);
	}
	CompositorBackend* backend = alloc::new(allocator, CompositorBackend, { .allocator = allocator, .poll = options.poll, .kind = kind });
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

<* Whether a switch can be sent to this compositor at all. *>
fn bool route_open(compositor::Kind kind) @private => kind != compositor::Kind.HYPRLAND;

<*
 The index of the active layout among `count` layouts: the compositor's own index when it reports one; the
 only layout when Hyprland names just that one; absent otherwise.
*>
fn Maybe{uint} current_index(compositor::KeyboardLayouts* keyboard, sz count) @private
{
	if (keyboard.current.has_value && keyboard.current.value >= 0 && (sz)keyboard.current.value < count)
	{
		return maybe::value((uint)keyboard.current.value);
	}
	if (keyboard.names.len == 0 && count == 1) return maybe::value((uint)0);
	return { };
}

<*
 The State a compositor model describes, with its text allocated in `allocator`. Callers hold a `@pool()`:
 the name mapping formats in tmem.
*>
fn State state_of(compositor::Model* model, Allocator allocator, bool route) @private
{
	compositor::KeyboardLayouts* keyboard = &model.layouts;
	sz count = keyboard.names.len > 0 ? keyboard.names.len : (keyboard.current_name.len > 0 ? 1 : 0);
	Layout[] layouts = alloc::new_array(allocator, Layout, count);
	for (sz i = 0; i < count; i++)
	{
		String text = keyboard.names.len > 0 ? keyboard.names[i] : keyboard.current_name;
		layouts[i] = names::layout_from_name(text, allocator);
	}
	return {
		.layouts = layouts,
		.current = current_index(keyboard, count),
		.can_switch = can_switch_now(route, count),
	};
}


<* Take the whole model again into the model arena, which is reset first. On failure the model is empty. *>
fn void? take_snapshot(Session* session, DynamicArenaAllocator* model_arena) @private
{
	model_arena.reset();
	Allocator allocator = model_arena;
	compositor::Model? taken = session.client.snapshot(allocator);
	if (catch err = taken)
	{
		session.model = { };
		return err~;
	}
	session.model = taken;
}

<*
 Connect to the compositor, watch its event socket and take the first model. False when the compositor
 cannot be reached or does not answer: nothing stays open then.
*>
fn bool open_session(Session* session, DynamicArenaAllocator* link_arena, DynamicArenaAllocator* model_arena, Poller* poller) @private
{
	Allocator link = link_arena;
	compositor::Detection detection = compositor::detect(link);
	if (try client = connect::open(link, detection))
	{
		if (catch poller.add({ .handle = client.event_handle(), .interest = { .readable = true }, .tag = EVENT_TAG }))
		{
			client.close();
			return false;
		}
		session.client = client;
		session.connected = true;
		if (catch take_snapshot(session, model_arena))
		{
			close_session(session, poller);
			return false;
		}
		return true;
	}
	return false;
}

<* Close the connection and take its source out of the poller. Safe when not connected. *>
fn void close_session(Session* session, Poller* poller) @private
{
	if (!session.connected) return;
	session.connected = false;
	// The source was added when the session opened, so the poller holds it.
	if (catch poller.remove(EVENT_TAG))
	{
		// Not registered: nothing to take out.
	}
	session.client.close();
}

<*
 Apply the events waiting on the socket. Returns true when the state must be published: the model changed,
 or the connection was lost, which leaves the state empty.
*>
fn bool drain(Session* session, Poller* poller, DynamicArenaAllocator* model_arena) @private
{
	Allocator allocator = model_arena;
	if (try refresh = session.client.read_events(&session.model, allocator))
	{
		if (refresh == backend::Refresh.NONE) return false;
		if (refresh == backend::Refresh.UPDATED) return true;
		// The event does not carry the change: take the model again. A failure leaves the state empty.
		if (catch take_snapshot(session, model_arena))
		{
			close_session(session, poller);
		}
		return true;
	}
	// The socket closed or sent something that is not the protocol: reconnect on a later tick.
	close_session(session, poller);
	return true;
}

// Publish the model of the open session, or an empty state when there is none.
fn void publish_session(CompositorBackend* backend, Session* session, InputHub* hub) @private
{
	Snapshot{State}* snapshot = hub.begin();
	if (session.connected)
	{
		@pool()
		{
			snapshot.value = state_of(&session.model, snapshot.allocator(), route_open(backend.kind));
		};
	}
	publish_state(hub, snapshot);
}

<*
 Make the layout `id` active. The compositor takes the index of the layout among the names it reports, which
 is the index in the state this backend publishes.
*>
fn void? activate(Session* session, String id) @private
{
	sz index = -1;
	@pool()
	{
		State state = state_of(&session.model, tmem, true);
		index = index_of(state.layouts, id);
	};
	if (index < 0) return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no layout '%s' in the compositor's list", id)~;
	return session.client.set_layout((uint)index);
}

<* Carry out one queued command. Returns true when the model changed and must be published. *>
fn bool handle(CompositorBackend* backend, Session* session, Poller* poller, Command* command, DynamicArenaAllocator* model_arena) @private
{
	switch (command.kind)
	{
		case CommandKind.REFRESH:
			if (!session.connected) return false;
			if (catch take_snapshot(session, model_arena))
			{
				close_session(session, poller);
			}
			return true;
		case CommandKind.SWITCH_TO:
			SwitchOperation* operation = command.operation;
			if (!route_open(backend.kind))
			{
				fail_switch(operation, error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "Hyprland cannot be given a layout index"));
				return false;
			}
			if (!session.connected)
			{
				fail_switch(operation, error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "the compositor is not connected"));
				return false;
			}
			if (catch err = activate(session, command.id_text()))
			{
				fail_switch(operation, err);
			}
			else
			{
				succeed_switch(operation, SwitchOutcome.ACKNOWLEDGED);
			}
			return false;
	}
}

fn void run(void* state, InputHub* hub, Host{Command}* host)
{
	CompositorBackend* backend = (CompositorBackend*)state;
	DynamicArenaAllocator link_arena;
	link_arena.init(mem, ARENA_PAGE);
	defer link_arena.free();
	DynamicArenaAllocator model_arena;
	model_arena.init(mem, ARENA_PAGE);
	defer model_arena.free();
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 2)) return;
	defer poller.free();
	Session session;
	defer close_session(&session, &poller);
	Command[COMMAND_BATCH] commands;
	open_session(&session, &link_arena, &model_arena, &poller);
	publish_session(backend, &session, hub);
	while (!host.stopping())
	{
		// A timeout is normal: the poll interval passed without an event, and the connection is checked below.
		if (catch poller.wait(backend.poll))
		{
			// Nothing ready.
		}
		bool changed = false;
		if (session.connected) changed = drain(&session, &poller, &model_arena);
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++)
		{
			changed = handle(backend, &session, &poller, &commands[i], &model_arena) || changed;
		}
		if (!session.connected)
		{
			// Reconnect: the memory of the previous connection is released first.
			link_arena.reset();
			changed = open_session(&session, &link_arena, &model_arena, &poller) || changed;
		}
		if (changed) publish_session(backend, &session, hub);
	}
}
