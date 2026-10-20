<*
 The contract every compositor client implements: a model snapshot, incremental
 event application, and window-manager actions.

 A client is used from one thread at a time. `read_events` never blocks once the
 event socket is non-blocking, so a shell can wait on `event_handle` with a
 poller and then drain the events it reports.
*>
module bleu::compositor::backend;
import bleu::error, bleu::rt, bleu::compositor;

<*
 A request a shell can make of the compositor. Each one names an existing
 window or workspace by the ids of `compositor::Model`.
*>
enum Action : char
{
	FOCUS_WINDOW,
	CLOSE_WINDOW,
	SWITCH_WORKSPACE,
	MOVE_WINDOW,
	SET_LAYOUT,
	TOGGLE_FLOATING,
	TOGGLE_FULLSCREEN,
}

<*
 What applying events did to a model.

 `NONE`: nothing the model holds changed. `UPDATED`: the model was changed in
 place and is current. `REFRESH_NEEDED`: the event says the model changed in a
 way the event does not carry, so the caller must take a new `snapshot`.
 When several events are combined, the strongest wins in this order.
*>
enum Refresh : char
{
	NONE,
	UPDATED,
	REFRESH_NEEDED,
}

<*
 One event as a compositor sent it: its name and the rest of the message as
 text (Hyprland `name>>data`, sway event type name with its JSON, niri variant
 name with its JSON object). Interpreted by the backend's `apply_event`.
*>
struct RawEvent
{
	String name;
	String payload;
}

<*
 The stronger of two refresh outcomes.

 @return "`REFRESH_NEEDED` if either is, else `UPDATED` if either is, else `NONE`"
*>
fn Refresh combine(Refresh a, Refresh b)
{
	if (a == REFRESH_NEEDED || b == REFRESH_NEEDED) return REFRESH_NEEDED;
	if (a == UPDATED || b == UPDATED) return UPDATED;
	return NONE;
}

<*
 A connection to one compositor. Methods are synchronous and run on the caller's
 thread. `close` releases the connection and the backend; the interface value
 must not be used afterwards.

 Ids: `window_id` and `id` arguments are `Window.id` and `Workspace.id` values from
 the model. An id the compositor no longer knows fails with NOT_FOUND.
*>
interface Backend
{
	<* The compositor this client talks to. *>
	fn compositor::Kind kind();

	<* The file descriptor that becomes readable when events wait. Owned by the backend. *>
	fn rt::Native event_handle();

	<*
	 Ask the compositor for its whole state.

	 @param allocator : "Long-lived allocator for the model (not tmem)"
	 @return? error::PROTOCOL : "The reply did not match the documented format"
	 @return? error::DISCONNECTED, error::BACKEND_FAILURE : "The socket failed"
	*>
	fn compositor::Model? snapshot(Allocator allocator);

	<*
	 Read every event that is waiting, without blocking, and apply each to `model`.

	 @param allocator : "Allocator for new arrays and strings in `model` (not tmem)"
	 @return "The strongest `Refresh` among the events read; NONE when none waited"
	 @return? error::DISCONNECTED : "The compositor closed the event socket"
	 @return? error::PROTOCOL : "An event line was malformed or longer than the limit"
	*>
	fn Refresh? read_events(compositor::Model* model, Allocator allocator);

	<*
	 Apply one event to `model`. Pure with respect to the connection.

	 @param allocator : "Allocator for new arrays and strings in `model` (not tmem)"
	*>
	fn Refresh apply_event(compositor::Model* model, Allocator allocator, RawEvent event);

	<* Focus a window (and its workspace, as the compositor does). *>
	fn void? focus_window(String window_id);

	<* Ask the window to close, as its close button would. *>
	fn void? close_window(String window_id);

	<* Show a workspace on its output. *>
	fn void? switch_workspace(String id);

	<* Move a window to a workspace without changing focus. *>
	fn void? move_window(String window_id, String workspace_id);

	<*
	 Make a keyboard layout the active one.

	 @param index : "Position in `KeyboardLayouts.names` of the main keyboard"
	*>
	fn void? set_layout(uint index);

	<* Toggle floating for a window. *>
	fn void? toggle_floating(String window_id);

	<* Toggle fullscreen for a window. *>
	fn void? toggle_fullscreen(String window_id);

	<* Release the connection and the backend. *>
	fn void close();
}
