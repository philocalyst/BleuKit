<*
 The work queue of the worker. Handlers that run inside `process()` may not make bus calls, so
 they queue what must be done, and the worker does it after `process()` returns. Names and text
 are copied into the backend's allocator when queued, and freed when done.
*>
module bleu::tray::sni @feat(LINUX);
import bleu::tray;

enum PendingKind : char
{
	ADD_ITEM, // `text` is the registration to add ("bus/path")
	REMOVE_ITEM, // `text` is the registration to remove
	OWNER_GONE, // the bus name `text` has no owner: remove every item of it
	PROPERTY, // re-read property `prop` of the item with `key`
	MENU, // re-read the menu of the item with `key`
	WATCHER_CHANGED, // the watcher name changed owner; `text` is the new owner ("" when none)
	WATCHER_LOST, // we held the watcher name and lost it
}

<* One unit of queued work. `text` is owned by the backend (see `push_pending`). *>
struct Pending
{
	PendingKind kind;
	uint key;
	Prop prop;
	String text;
}

<*
 Queue one unit of work. Beyond `PENDING_LIMIT` the work is dropped and the backend re-reads
 everything, which is cheaper than an unbounded queue fed by remote processes.
*>
fn void push_pending(SniBackend* b, PendingKind kind, uint key, Prop prop, String text)
{
	if ((usz)b.pending.len() >= PENDING_LIMIT)
	{
		b.needs_resync = true;
		return;
	}
	b.pending.push({ .kind = kind, .key = key, .prop = prop, .text = convert::copy_text(text, b.allocator) });
}

// Frees every queued unit of work without running it.
fn void clear_pending(SniBackend* b)
{
	while (try p = b.pending.pop_first())
	{
		if (p.text.len > 0) alloc::free(b.allocator, p.text.ptr);
	}
}

// Runs the queued work in order. Work queued while running is run too.
fn void process_pending(SniBackend* b)
{
	if (b.needs_resync)
	{
		b.needs_resync = false;
		clear_pending(b);
		resync_records(b);
	}
	while (try p = b.pending.pop_first())
	{
		handle_pending(b, p);
		if (p.text.len > 0) alloc::free(b.allocator, p.text.ptr);
	}
}

// Runs one unit of work.
fn void handle_pending(SniBackend* b, Pending p)
{
	switch (p.kind)
	{
		case ADD_ITEM:
			add_item(b, p.text);
		case REMOVE_ITEM:
			remove_item_by_id(b, p.text);
		case OWNER_GONE:
			owner_gone(b, p.text);
		case PROPERTY:
			handle_property(b, p);
		case MENU:
			handle_menu(b, p);
		case WATCHER_CHANGED:
			attach_watcher(b);
		case WATCHER_LOST:
			if (b.watcher_name)
			{
				if (catch b.watcher_name.release()) {}
				b.watcher_name = null;
			}
			b.watcher_served = false;
			attach_watcher(b);
	}
}

// A property of the item named by the work changed, if the item is still registered.
fn void handle_property(SniBackend* b, Pending p)
{
	ItemRecord* r = find_record_by_key(b, p.key);
	if (r != null) property_changed(b, r, p.prop);
}

// The menu of the item named by the work changed, if the item is still registered.
fn void handle_menu(SniBackend* b, Pending p)
{
	ItemRecord* r = find_record_by_key(b, p.key);
	if (r != null) menu_changed(b, r);
}

// A property of an item changed: read it again, then its menu if the menu's place changed.
fn void property_changed(SniBackend* b, ItemRecord* r, Prop prop)
{
	read_prop(b, r, prop);
	if (prop == MENU_PATH)
	{
		if (catch reload_menu(b, r, -1)) {}
	}
	queue_event(b, ITEM_CHANGED, r.item.id, 0, 0, 0);
	b.dirty = true;
}

// The item's menu changed: read the menu again.
fn void menu_changed(SniBackend* b, ItemRecord* r)
{
	if (catch reload_menu(b, r, -1)) {}
	queue_event(b, MENU_CHANGED, r.item.id, 0, 0, 0);
	b.dirty = true;
}

// Rebuild every item from scratch: the watcher we serve, or the one we follow, after an overflow.
fn void resync_records(SniBackend* b)
{
	forget_records(b);
	if (b.watcher_served)
	{
		for (sz i = 0; i < b.registry.len(); i++) add_item(b, b.registry[i]);
	}
	else
	{
		if (catch read_registered(b)) {}
	}
	b.dirty = true;
}
