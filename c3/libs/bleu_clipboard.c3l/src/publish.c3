<*
 What every backend does with its `Board` after a batch of work: publish a complete snapshot
 when it changed, and emit the transients. Platform-neutral.
*>
module bleu::clipboard;
import bleu::observe, bleu::operation, bleu::stream, bleu::service, bleu::rt::worker;

<* Publish the board's current view as a new snapshot, unless it equals the latest one. *>
fn void publish_board(ClipboardHub* hub, Board* board)
{
	Snapshot{State}* snapshot = hub.begin();
	board.build(snapshot.allocator(), &snapshot.value);
	hub.publish_if_changed(snapshot);
}

<* Emit one transient event. *>
fn void emit_event(ClipboardHub* hub, EventKind kind, Slot slot)
{
	Packet{Event}* packet = hub.emit_begin();
	packet.value = { .kind = kind, .slot = slot };
	hub.emit(packet);
}
<*
 Complete a command that will never run with `failure`, and drop the worker's reference to its
 operation. Used when a worker stops, so that no caller waits for it.
*>
fn void fail_command(Command* command, fault failure)
{
	switch (command.kind)
	{
		case CommandKind.SET:

			{
				Operation{ulong}* op = (Operation{ulong}*)command.operation;
				op.fail(failure);
				op.release();
			}
		case CommandKind.CLEAR:
		case CommandKind.DELETE:

			{
				Operation{bool}* op = (Operation{bool}*)command.operation;
				op.fail(failure);
				op.release();
			}
		case CommandKind.FETCH:

			{
				Operation{Bytes}* op = (Operation{Bytes}*)command.operation;
				op.fail(failure);
				op.release();
			}
	}
}

<* Fail every command still queued for the worker. Call on the worker's way out. *>
fn void fail_pending(Host{Command}* host, fault failure)
{
	Command[8] queued;
	usz count = host.mailbox().take_all(queued[..]);
	while (count > 0)
	{
		for (usz i = 0; i < count; i++) fail_command(&queued[i], failure);
		count = host.mailbox().take_all(queued[..]);
	}
}