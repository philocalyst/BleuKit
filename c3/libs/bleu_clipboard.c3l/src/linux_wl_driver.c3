<*
 The Wayland backend: the driver entry, the worker loop, and the handling of commands.

 `create` connects once to learn what the compositor offers (the capabilities), and disconnects.
 The worker then connects for itself, since a Wayland client belongs to one thread. If the
 connection drops, the worker stops and the state reports nothing, because nothing is known
 about the selections any more.
*>
module bleu::clipboard::linux_wl @feat(LINUX);
import bleu::clipboard, bleu::availability, bleu::error, bleu::operation, bleu::rt::worker, bleu::service, std::os::env;

<* The worker's state: the board and the session it fills. The board is written only by the worker. *>
struct WlBackend
{
	Allocator allocator;
	Board board;
	WlSession session;
}

const Driver DRIVER = {
	.info = { "wayland", "Wayland data-control (ext-data-control-v1, wlr-data-control-unstable-v1)", 20 },
	.id = Backend.WAYLAND,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// The compositor is named by WAYLAND_DISPLAY, or inherited as WAYLAND_SOCKET.
fn bool probe(Options* options)
{
	return has_variable("WAYLAND_DISPLAY") || has_variable("WAYLAND_SOCKET");
}

fn bool has_variable(String name) @private
{
	return (env::tget_var(name) ?? "").len > 0;
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	WlBackend* backend = alloc::new(allocator, WlBackend);
	backend.allocator = allocator;
	backend.board.init(allocator, options.history_items, options.history_bytes, options.payload_limit);
	backend.session.init(allocator, &backend.board, options.transfer_timeout);
	if (catch err = backend.session.connect_env())
	{
		backend.board.free();
		alloc::free(allocator, backend);
		return err~;
	}
	capabilities.init(availability::YES);
	if (!backend.session.primary_supported)
	{
		capabilities.set(
			Cap.PRIMARY_SELECTION,
			availability::no(
				availability::Reason.UNSUPPORTED_BACKEND,
				"the compositor's wlr-data-control has no primary selection (version 1)"
			)
		);
	}
	backend.session.disconnect();
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	WlBackend* backend = (WlBackend*)state;
	backend.session.free();
	backend.board.free();
	alloc::free(allocator, backend);
}

<* The worker: connect, then serve the socket, the transfers and the commands until the service stops. *>
fn void run(void* state, ClipboardHub* hub, Host{Command}* host)
{
	WlBackend* backend = (WlBackend*)state;
	WlSession* session = &backend.session;
	session.wakeup = host.wakeup();
	clipboard::publish_board(hub, &backend.board);
	if (catch session.connect_env()) return;
	defer session.disconnect();
	Command[8] commands;
	while (!host.stopping())
	{
		if (catch session.pump(IDLE_WAIT)) break;
		if (session.is_finished()) break;
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++) execute(session, &commands[i]);
		if (catch session.client.flush()) break;
		emit_changes(session, hub);
	}
	backend.board.clear(Slot.CLIPBOARD);
	backend.board.clear(Slot.PRIMARY);
	clipboard::publish_board(hub, &backend.board);
}

// Emit what changed for each selection, then publish the board.
fn void emit_changes(WlSession* session, ClipboardHub* hub) @private
{
	Slot[2] slots = { Slot.CLIPBOARD, Slot.PRIMARY };
	foreach (slot : slots)
	{
		if (session.take_selection_changed(slot)) clipboard::emit_event(hub, EventKind.SELECTION_CHANGED, slot);
		if (session.take_ownership_lost(slot)) clipboard::emit_event(hub, EventKind.OWNERSHIP_LOST, slot);
	}
	clipboard::publish_board(hub, session.board);
}

// Run one command, completing its operation.
fn void execute(WlSession* session, Command* command) @private
{
	switch (command.kind)
	{
		case CommandKind.SET: run_set(session, command);
		case CommandKind.CLEAR: run_clear(session, command);
		case CommandKind.FETCH: run_fetch(session, command);
		case CommandKind.DELETE: run_delete(session, command);
	}
}

fn void run_set(WlSession* session, Command* command) @private
{
	Operation{ulong}* op = (Operation{ulong}*)command.operation;
	defer op.release();
	ulong? seq = session.own(command.slot, command.representations);
	if (catch err = seq)
	{
		op.fail(err);
		return;
	}
	op.succeed(seq);
}

fn void run_clear(WlSession* session, Command* command) @private
{
	Operation{bool}* op = (Operation{bool}*)command.operation;
	defer op.release();
	op.succeed(session.clear(command.slot));
}

fn void run_delete(WlSession* session, Command* command) @private
{
	Operation{bool}* op = (Operation{bool}*)command.operation;
	defer op.release();
	op.succeed(session.board.delete(command.id));
}

<*
 A fetch: from the history when the entry holds the type, otherwise from the live selection
 when the entry is still the current one. An offer this service owns is served from memory.
*>
fn void run_fetch(WlSession* session, Command* command) @private
{
	Operation{Bytes}* op = (Operation{Bytes}*)command.operation;
	Item* item = session.board.find(command.id);
	if (item != null && item.mime == command.mime)
	{
		complete_bytes(op, item.bytes);
		return;
	}
	Lane* lane = session.board.lane(Slot.CLIPBOARD);
	if (!lane.present || lane.seq != command.id)
	{
		fail_fetch(op, error::UNAVAILABLE);
		return;
	}
	WlSource* own = session.current_source(Slot.CLIPBOARD);
	if (own != null)
	{
		fetch_own(op, own, command.mime);
		return;
	}
	WlOffer* offer = session.lane_offers[Slot.CLIPBOARD.ordinal];
	if (offer == null)
	{
		fail_fetch(op, error::UNAVAILABLE);
		return;
	}
	if (catch err = session.start_receive(offer, Slot.CLIPBOARD, command.id, command.mime, op))
	{
		fail_fetch(op, err);
	}
}

// Serve `mime` of our own source from memory.
fn void fetch_own(Operation{Bytes}* op, WlSource* source, String mime) @private
{
	foreach (representation : source.representations)
	{
		if (representation.mime == mime)
		{
			complete_bytes(op, representation.bytes);
			return;
		}
	}
	fail_fetch(op, NOT_FOUND);
}

// Complete a fetch with a copy of `bytes`, and drop the command's reference.
fn void complete_bytes(Operation{Bytes}* op, char[] bytes) @private
{
	Bytes copy = bytes.len == 0 ? { } : alloc::clone_slice(op.allocator(), bytes);
	op.succeed(copy);
	op.release();
}

// Fail a fetch and drop the command's reference.
fn void fail_fetch(Operation{Bytes}* op, fault failure) @private
{
	op.fail(failure);
	op.release();
}
