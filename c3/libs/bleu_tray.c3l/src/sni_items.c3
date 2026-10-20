<*
 The registered items: adding and removing them, subscribing to their signals and owner
 changes, and reading their properties. A record's memory lives in its arenas; a property
 change resets only that property's arena.
*>
module bleu::tray::sni @feat(LINUX);
import bleu::dbus::bus, bleu::dbus::connection, bleu::dbus::marshal, bleu::dbus::match, bleu::dbus::message, bleu::error, bleu::tray, bleu::tray::convert;

// Arena page sizes: identity strings, one property, and the menu tree.
const usz IDENTITY_PAGE = 256;
const usz PROPERTY_PAGE = 512;
const usz MENU_PAGE     = 1024;

// The record with this identifier (bus name and object path), or null.
fn ItemRecord* find_record_by_id(SniBackend* b, String id)
{
	for (sz i = 0; i < b.items.len(); i++)
	{
		if (b.items[i].item.id == id) return b.items[i];
	}
	return null;
}

// The record with this key, or null when it has been removed.
fn ItemRecord* find_record_by_key(SniBackend* b, uint key)
{
	for (sz i = 0; i < b.items.len(); i++)
	{
		if (b.items[i].key == key) return b.items[i];
	}
	return null;
}

// Start tracking the item named by the registration `text` ("bus/path"). Our own icon is skipped.
fn void add_item(SniBackend* b, String text)
{
	if (find_record_by_id(b, text) != null) return;
	if (try reg = convert::parse_registration(text, ""))
	{
		if (reg.bus_name == b.own_bus) return;
		new_record(b, reg, text);
	}
}

// Create, subscribe and read one record. The record is kept only once its subscriptions exist.
fn void new_record(SniBackend* b, convert::Registration reg, String text)
{
	ItemRecord* r = alloc::new(b.allocator, ItemRecord, { .backend = b });
	b.next_key++;
	r.key = b.next_key;
	init_arenas(b, r);
	Allocator identity = &r.identity;
	r.item.bus_name = convert::copy_text(reg.bus_name, identity);
	r.item.object_path = convert::copy_text(reg.object_path, identity);
	r.item.id = convert::copy_text(text, identity);
	if (catch subscribe_record(b, r))
	{
		free_record_memory(b, r);
		return;
	}
	b.items.push(r);
	read_everything(b, r);
	queue_event(b, ITEM_ADDED, r.item.id, 0, 0, 0);
	b.dirty = true;
}

fn void init_arenas(SniBackend* b, ItemRecord* r)
{
	r.identity.init(b.allocator, IDENTITY_PAGE);
	for (usz i = 0; i < PROP_COUNT; i++) r.arenas[i].init(b.allocator, PROPERTY_PAGE);
	r.menu_arena.init(b.allocator, MENU_PAGE);
}

// Frees a record's arenas and the record. Its subscriptions must already be gone.
fn void free_record_memory(SniBackend* b, ItemRecord* r)
{
	r.identity.free();
	for (usz i = 0; i < PROP_COUNT; i++) r.arenas[i].free();
	r.menu_arena.free();
	alloc::free(b.allocator, r);
}

// Stop tracking the item at `index`: its subscriptions go, its event is queued, its memory is freed.
fn void remove_record_at(SniBackend* b, sz index)
{
	ItemRecord* r = b.items[index];
	b.items.remove_at(index);
	unsubscribe_record(b, r);
	queue_event(b, ITEM_REMOVED, r.item.id, 0, 0, 0);
	free_record_memory(b, r);
	b.dirty = true;
}

// Remove every record: the bus went away, or the watcher is about to be read again.
fn void forget_records(SniBackend* b)
{
	while (b.items.len() > 0)
	{
		remove_record_at(b, b.items.len() - 1);
	}
}

// Remove the item with this identifier, from the registry too when we serve it.
fn void remove_item_by_id(SniBackend* b, String id)
{
	for (sz i = 0; i < b.items.len(); i++)
	{
		if (b.items[i].item.id != id) continue;
		if (b.watcher_served) remove_registration(b, id);
		remove_record_at(b, i);
		return;
	}
}

// The bus name lost its owner: every item it had is gone.
fn void owner_gone(SniBackend* b, String bus_name)
{
	sz i = b.items.len();
	while (i > 0)
	{
		i--;
		if (b.items[i].item.bus_name != bus_name) continue;
		if (b.watcher_served) remove_registration(b, b.items[i].item.id);
		remove_record_at(b, i);
	}
}

// Subscribe to the item's signals (sent by its bus name) and to its bus name's owner changes.
fn void? subscribe_record(SniBackend* b, ItemRecord* r)
{
	match::Match rule;
	rule.init(b.allocator);
	rule.with_type(message::MessageType.SIGNAL)!;
	rule.with_sender(r.item.bus_name)!;
	r.signal_sub = b.connection.subscribe(rule, &on_item_signal, r)!;
	match::Match owner;
	owner.init(b.allocator);
	owner.with_type(message::MessageType.SIGNAL)!;
	owner.with_sender(connection::BUS_NAME)!;
	owner.with_interface(connection::BUS_INTERFACE)!;
	owner.with_member(bus::NAME_OWNER_CHANGED)!;
	owner.with_arg(0, r.item.bus_name)!;
	r.owner_sub = b.connection.subscribe(owner, &on_item_owner, r)!;
	r.subscribed = true;
}

// Ends the subscriptions of a record while the connection is up. Their handlers never run afterwards.
fn void unsubscribe_record(SniBackend* b, ItemRecord* r)
{
	if (!r.subscribed || !b.connection_up) return;
	if (catch b.connection.unsubscribe(r.signal_sub))
	{
	}
	if (catch b.connection.unsubscribe(r.owner_sub))
	{
	}
	r.subscribed = false;
}

// A signal from an item's bus name. Only the properties it names are queued for a re-read.
fn void on_item_signal(void* context, Message* signal)
{
	ItemRecord* r = (ItemRecord*)context;
	if (signal.path == r.item.object_path)
	{
		queue_item_signal(r, signal.member);
	}
	else if (r.item.menu_path.len > 0 && signal.path == r.item.menu_path && signal.interface_name == MENU_INTERFACE)
	{
		if (signal.member == "LayoutUpdated" || signal.member == "ItemsPropertiesUpdated")
		{
			push_pending(r.backend, MENU, r.key, ID, "");
		}
	}
}

// The item's own signals, mapped to the properties they change (the specification's names).
fn void queue_item_signal(ItemRecord* r, String member)
{
	SniBackend* b = r.backend;
	switch (member)
	{
		case "NewTitle": push_pending(b, PROPERTY, r.key, TITLE, "");
		case "NewStatus": push_pending(b, PROPERTY, r.key, STATUS, "");
		case "NewIcon":
			push_pending(b, PROPERTY, r.key, ICON_NAME, "");
			push_pending(b, PROPERTY, r.key, ICON_PIXMAP, "");
		case "NewAttentionIcon":
			push_pending(b, PROPERTY, r.key, ATTENTION_NAME, "");
			push_pending(b, PROPERTY, r.key, ATTENTION_PIXMAP, "");
		case "NewOverlayIcon":
			push_pending(b, PROPERTY, r.key, OVERLAY_NAME, "");
			push_pending(b, PROPERTY, r.key, OVERLAY_PIXMAP, "");
		case "NewToolTip": push_pending(b, PROPERTY, r.key, TOOLTIP, "");
		case "NewMenu": push_pending(b, PROPERTY, r.key, MENU_PATH, "");
		default: return;
	}
}

// The bus name of an item changed owner. When it has none, the item is gone.
fn void on_item_owner(void* context, Message* signal)
{
	ItemRecord* r = (ItemRecord*)context;
	String name;
	String old_owner;
	String new_owner;
	if (catch bus::name_owner_change(signal, &name, &old_owner, &new_owner)) return;
	if (new_owner.len == 0) push_pending(r.backend, OWNER_GONE, 0, ID, r.item.bus_name);
}

// Read every property of the item, then its menu. The interface is the one that answers. An item
// that answers neither interface (it hung, or it went away) is left empty: the bus call timeout
// bounds what a single unresponsive item can cost the worker to two calls.
fn void read_everything(SniBackend* b, ItemRecord* r)
{
	if (try interface_name = pick_interface(b, r))
	{
		r.interface_name = interface_name;
		for (usz i = 0; i < PROP_COUNT; i++) read_prop(b, r, (Prop)(char)i);
		if (catch reload_menu(b, r, -1))
		{
		}
	}
	b.dirty = true;
}

// The KDE interface when the item serves it, otherwise the freedesktop one. Neither: UNAVAILABLE.
fn String? pick_interface(SniBackend* b, ItemRecord* r)
{
	if (try reply = get_property(b, r.item.bus_name, r.item.object_path, ITEM_INTERFACE, "Id"))
	{
		reply.release();
		return ITEM_INTERFACE;
	}
	if (try reply = get_property(b, r.item.bus_name, r.item.object_path, ITEM_INTERFACE_FDO, "Id"))
	{
		reply.release();
		return ITEM_INTERFACE_FDO;
	}
	return error::UNAVAILABLE~;
}

<*
 Read one property into the record. A property that cannot be read, or has a type other than
 the specification's, reads as empty: the item still shows, without that part.
*>
fn void read_prop(SniBackend* b, ItemRecord* r, Prop prop)
{
	r.arenas[prop.ordinal].reset();
	clear_prop(r, prop);
	if (try reply = get_property(b, r.item.bus_name, r.item.object_path, r.interface_name, property_name(prop)))
	{
		defer reply.release();
		if (catch parse_reply(reply, prop, r)) clear_prop(r, prop);
	}
}

// The reply to Get holds one variant. Its contents must have the property's type.
fn void? parse_reply(Message* reply, Prop prop, ItemRecord* r)
{
	Reader rd       = reply.reader()!;
	String contents = rd.begin_variant()!;
	if (contents != expected_signature(prop)) return error::PROTOCOL~;
	parse_prop(&rd, prop, r, &r.arenas[prop.ordinal])!;
}