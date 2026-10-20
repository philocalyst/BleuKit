<*
 The tray service: open it, read `latest()`, wait for changes, ask items to act.

 Tray* tray = tray::open(mem, { .publish_own = true, .own = { .title = "Bleu", .icon = "applications-internet" } })!;
 defer tray.close();
 if (try snapshot = tray.latest())
 {
 defer snapshot.release();
 // snapshot.value.items: the tray items of the other applications
 }
 if (try op = tray.activate(item_id, 0, 0)) op.wait(time::ms(2000))!;

 Every method may be called from any thread. Commands return an `Operation`, which the
 worker completes once the item has answered (or failed to).
*>
module bleu::tray;
import std::collections::enummap, std::time, bleu::error, bleu::availability, bleu::observe, bleu::stream, bleu::service, bleu::operation;

alias TrayHub = Hub{State, Command, Event};
alias Capabilities = EnumMap{Cap, Availability};

struct Tray
{
	Allocator allocator;
	TrayHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
}

<*
 Open the first working backend of this platform, or the one named in `options`. Our own
 icon is published once the backend is running.

 @param allocator : "Allocator for the service, its commands and its snapshots"
 @return? error::UNAVAILABLE : "No backend works here (no session bus, no tray)"
 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
 @return? error::INVALID_ARGUMENT : "`publish_own` without a title, or an own menu entry with an id below 1 or a duplicate id"
*>
fn Tray*? open(Allocator allocator, Options options = { })
{
	if (options.publish_own && options.own.title.len == 0) return error::INVALID_ARGUMENT~;
	Driver* driver = select_driver(options)!;
	Tray* self     = alloc::new(allocator, Tray);
	self.allocator = allocator;
	self.driver = driver;
	self.driver_state = driver.create(allocator, options, &self.capabilities)!;
	if (catch err = self.hub.start(allocator, "tray", driver.info.name, driver.run, self.driver_state))
	{
		driver.destroy(allocator, self.driver_state);
		alloc::free(allocator, self);
		return err~;
	}
	return self;
}

<* Stop the backend, withdraw our own icon, and release everything. *>
fn void Tray.close(&self)
{
	self.hub.stop();
	self.hub.free();
	self.driver.destroy(self.allocator, self.driver_state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend in use, for diagnostics ("sni", "win32", "appkit"). *>
fn String Tray.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Tray.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The backend has not produced its first state yet"
*>
fn Snapshot{State}*? Tray.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`, then pass the previous
 snapshot's `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn Snapshot{State}*? Tray.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later state. Quick and non-blocking only. *>
fn WatchId{State} Tray.watch(&self, Listener{State} listener, void* context) => self.hub.state.watch(listener, context);

<* Remove a listener; when this returns it is not running. Not from inside a listener. *>
fn void? Tray.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<* Subscribe to transient events: items added and removed, and clicks on our own icon and menu. *>
fn Reader{Event}*? Tray.subscribe(&self) => self.hub.events.subscribe();

<*
 Ask the item to act as if clicked with the primary button at screen position (x, y).

 @return? error::UNSUPPORTED : "This backend cannot act on other items"
 @return? error::UNAVAILABLE : "The backend is stopping"
*>
fn CommandOp*? Tray.activate(&self, String item_id, int x, int y)
{
	return submit(self, Cap.ACTIVATE, { .kind = ACTIVATE, .x = x, .y = y }, item_id);
}

<* Ask the item to act as if clicked with the middle button at (x, y). *>
fn CommandOp*? Tray.secondary_activate(&self, String item_id, int x, int y)
{
	return submit(self, Cap.ACTIVATE, { .kind = SECONDARY_ACTIVATE, .x = x, .y = y }, item_id);
}

<* Ask the item to show its context menu at (x, y), as a right click does. *>
fn CommandOp*? Tray.context_menu(&self, String item_id, int x, int y)
{
	return submit(self, Cap.ACTIVATE, { .kind = CONTEXT_MENU, .x = x, .y = y }, item_id);
}

<* Send a wheel step of `delta` to the item, horizontal or vertical. *>
fn CommandOp*? Tray.scroll(&self, String item_id, int delta, bool horizontal)
{
	return submit(self, Cap.ACTIVATE, { .kind = SCROLL, .delta = delta, .horizontal = horizontal }, item_id);
}

<*
 Load the children of submenu `menu_id` before it is shown (DBusMenu AboutToShow). The
 operation's value is true when the item changed the menu; the state then carries the new menu.
*>
fn CommandOp*? Tray.open_submenu(&self, String item_id, int menu_id)
{
	return submit(self, Cap.MENU, { .kind = OPEN_SUBMENU, .menu_id = menu_id }, item_id);
}

<* Click entry `menu_id` of the item's menu (DBusMenu Event "clicked"). *>
fn CommandOp*? Tray.click_menu(&self, String item_id, int menu_id)
{
	return submit(self, Cap.MENU_CLICK, { .kind = CLICK_MENU, .menu_id = menu_id }, item_id);
}

<* Read every item again now, instead of waiting for its next signal. *>
fn void? Tray.refresh(&self) => self.hub.post({ .kind = REFRESH });

// Check the capability, copy the item name into the command, and queue it. The operation has
// two references, the caller's and the worker's; the worker releases its own when it completes
// the command. The worker frees the name copy. A failed post undoes both here.
fn CommandOp*? submit(Tray* tray, Cap cap, Command command, String item_id) @private
{
	Availability availability = tray.capabilities.values[cap.ordinal];
	if (!availability.ok()) return availability.refusal()~;
	command.item_id = item_id.copy(tray.allocator);
	CommandOp* op = operation::begin{bool}(tray.allocator);
	command.op = op.retain();
	if (catch err = tray.hub.post(command))
	{
		alloc::free(tray.allocator, command.item_id.ptr);
		op.release(); // the worker's reference, which is never used
		op.release(); // the caller's reference, which is never handed out
		return err~;
	}
	return op;
}