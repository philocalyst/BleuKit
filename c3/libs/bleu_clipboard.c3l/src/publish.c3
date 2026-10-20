<*
 What every backend does with its `Board` after a batch of work: publish a complete snapshot
 when it changed, and emit the transients. Platform-neutral.
*>
module bleu::clipboard;
import bleu::observe, bleu::stream, bleu::service;

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
