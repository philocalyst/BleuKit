<*
 The objects this process exports on the bus: the StatusNotifierWatcher (when we serve it), our
 own StatusNotifierItem, and its DBusMenu. Every handler runs inside `process()`, so it answers
 at once and queues anything that needs the bus to be called.
*>
module bleu::tray::sni @feat(LINUX);
import bleu::dbus::message, bleu::dbus::names, bleu::dbus::server, bleu::dbus::value, bleu::dbus::marshal, bleu::error, bleu::tray, bleu::tray::convert;

// The layout revision of our menu. The menu never changes after `open`, so it never advances.
const uint OWN_MENU_REVISION = 1;
// libdbusmenu's `Version` property: the protocol version it implements.
const uint DBUSMENU_VERSION = 3;
// The DBus error names a bad argument and an unknown method give.
const String ERROR_INVALID_ARGS = "org.freedesktop.DBus.Error.InvalidArgs";

// Fill the interface tables. They live in the backend, which the server points into.
fn void describe(SniBackend* b)
{
	b.watcher_methods = {
		{ .name = "RegisterStatusNotifierItem", .in_signature = "s", .handler = &watcher_register_item, .context = b },
		{ .name = "RegisterStatusNotifierHost", .in_signature = "s", .handler = &watcher_register_host, .context = b },
	};
	b.watcher_properties = {
		{ .name = "RegisteredStatusNotifierItems", .signature = "as", .access = READ, .changes = NEVER, .get = &watcher_items, .context = b },
		{ .name = "IsStatusNotifierHostRegistered", .signature = "b", .access = READ, .changes = NEVER, .get = &watcher_host_known, .context = b },
		{ .name = "ProtocolVersion", .signature = "i", .access = READ, .changes = CONST, .get = &watcher_protocol, .context = b },
	};
	b.watcher_signals = {
		{ .name = REGISTERED_SIGNAL, .signature = "s" },
		{ .name = UNREGISTERED_SIGNAL, .signature = "s" },
		{ .name = HOST_REGISTERED_SIGNAL, .signature = "" },
		{ .name = HOST_UNREGISTERED_SIGNAL, .signature = "" },
	};
	b.watcher_interfaces[0] = { .name = WATCHER_INTERFACE, .methods = b.watcher_methods[..], .properties = b.watcher_properties[..], .signals = b.watcher_signals[..] };
	b.item_methods = {
		{ .name = "Activate", .in_signature = "ii", .handler = &item_activate, .context = b },
		{ .name = "SecondaryActivate", .in_signature = "ii", .handler = &item_secondary_activate, .context = b },
		{ .name = "ContextMenu", .in_signature = "ii", .handler = &item_context_menu, .context = b },
		{ .name = "Scroll", .in_signature = "is", .handler = &item_scroll, .context = b },
	};
	b.item_properties = {
		{ .name = "Category", .signature = "s", .access = READ, .changes = CONST, .get = &own_category, .context = b },
		{ .name = "Id", .signature = "s", .access = READ, .changes = CONST, .get = &own_id, .context = b },
		{ .name = "Title", .signature = "s", .access = READ, .changes = CONST, .get = &own_id, .context = b },
		{ .name = "Status", .signature = "s", .access = READ, .changes = CONST, .get = &own_status, .context = b },
		{ .name = "IconName", .signature = "s", .access = READ, .changes = CONST, .get = &own_icon_name, .context = b },
		{ .name = "IconPixmap", .signature = "a(iiay)", .access = READ, .changes = CONST, .get = &own_no_pixmaps, .context = b },
		{ .name = "ItemIsMenu", .signature = "b", .access = READ, .changes = CONST, .get = &own_not_menu, .context = b },
		{ .name = "Menu", .signature = "o", .access = READ, .changes = CONST, .get = &own_menu_path, .context = b },
		{ .name = "ToolTip", .signature = "(sa(iiay)ss)", .access = READ, .changes = CONST, .get = &own_tooltip, .context = b },
		{ .name = "IconThemePath", .signature = "s", .access = READ, .changes = CONST, .get = &own_theme_path, .context = b },
	};
	b.item_interfaces[0] = { .name = ITEM_INTERFACE, .methods = b.item_methods[..], .properties = b.item_properties[..] };
	b.menu_methods = {
		{ .name = "GetLayout", .in_signature = "iias", .out_signature = "u(ia{sv}av)", .handler = &menu_layout, .context = b },
		{ .name = "Event", .in_signature = "isvu", .handler = &menu_event, .context = b },
		{ .name = "AboutToShow", .in_signature = "i", .out_signature = "b", .handler = &menu_about_to_show, .context = b },
	};
	b.menu_properties = {
		{ .name = "Version", .signature = "u", .access = READ, .changes = CONST, .get = &menu_version, .context = b },
		{ .name = "TextDirection", .signature = "s", .access = READ, .changes = CONST, .get = &menu_text_direction, .context = b },
		{ .name = "Status", .signature = "s", .access = READ, .changes = CONST, .get = &menu_status, .context = b },
	};
	b.menu_interfaces[0] = { .name = MENU_INTERFACE, .methods = b.menu_methods[..], .properties = b.menu_properties[..] };
}

// RegisterStatusNotifierItem(service): record the item and read it. The service is "bus", "bus/path" or "/path".
fn void? watcher_register_item(void* context, Call* call)
{
	SniBackend* b = (SniBackend*)context;
	Reader rd = call.reader()!;
	String argument = rd.read_string()!;
	convert::Registration reg = convert::parse_registration(argument, call.sender)!;
	@pool()
	{
		String item = convert::item_id(reg, tmem);
		if (add_registration(b, item)) push_pending(b, ADD_ITEM, 0, ID, item);
	};
	return call.reply({});
}

// RegisterStatusNotifierHost(service): a host shows the items; we only note that one exists.
fn void? watcher_register_host(void* context, Call* call)
{
	SniBackend* b = (SniBackend*)context;
	Reader rd = call.reader()!;
	String service = rd.read_string()!;
	if (!names::is_bus_name(service)) return error::INVALID_ARGUMENT~;
	if (!b.host_known)
	{
		b.host_known = true;
		b.dirty = true;
	}
	return call.reply({});
}

// The items registered with the watcher we serve, as the specification's `as`.
fn Value? watcher_items(void* context, String path, Allocator allocator)
{
	SniBackend* b = (SniBackend*)context;
	Value[] items = {};
	if (b.registry.len() > 0)
	{
		items = alloc::new_array(allocator, Value, b.registry.len());
		for (sz i = 0; i < b.registry.len(); i++)
		{
			items[i] = value::str(allocator, b.registry[i])!;
		}
	}
	return value::array(allocator, "s", items);
}

fn Value? watcher_host_known(void* context, String path, Allocator allocator)
{
	SniBackend* b = (SniBackend*)context;
	return value::boolean(b.host_known);
}

fn Value? watcher_protocol(void* context, String path, Allocator allocator)
{
	return value::i32(0);
}

// Our item's properties. The icon and the title are fixed for the life of the publication.

fn Value? own_category(void* context, String path, Allocator allocator) => value::str(allocator, "ApplicationStatus");

fn Value? own_id(void* context, String path, Allocator allocator)
{
	SniBackend* b = (SniBackend*)context;
	return value::str(allocator, b.own.title);
}

fn Value? own_status(void* context, String path, Allocator allocator) => value::str(allocator, "Active");

fn Value? own_icon_name(void* context, String path, Allocator allocator)
{
	SniBackend* b = (SniBackend*)context;
	return value::str(allocator, b.own.icon);
}

fn Value? own_no_pixmaps(void* context, String path, Allocator allocator)
{
	return value::array(allocator, "(iiay)", {});
}

fn Value? own_not_menu(void* context, String path, Allocator allocator) => value::boolean(false);

fn Value? own_menu_path(void* context, String path, Allocator allocator) => value::path(allocator, OWN_MENU_PATH);

fn Value? own_theme_path(void* context, String path, Allocator allocator) => value::str(allocator, "");

<* The tooltip: no icon, our title, no description. `(sa(iiay)ss)`. *>
fn Value? own_tooltip(void* context, String path, Allocator allocator)
{
	SniBackend* b = (SniBackend*)context;
	Value[] fields = {
		value::str(allocator, "")!,
		value::array(allocator, "(iiay)", {})!,
		value::str(allocator, b.own.title)!,
		value::str(allocator, "")!,
	};
	return value::structure(allocator, fields);
}

// Activate(x, y): the user clicked our icon. The application decides what that means.
fn void? item_activate(void* context, Call* call)
{
	SniBackend* b = (SniBackend*)context;
	Reader rd = call.reader()!;
	int x = rd.read_i32()!;
	int y = rd.read_i32()!;
	queue_event(b, OWN_ACTIVATED, b.own_item_id, 0, x, y);
	return call.reply({});
}

fn void? item_secondary_activate(void* context, Call* call)
{
	SniBackend* b = (SniBackend*)context;
	Reader rd = call.reader()!;
	int x = rd.read_i32()!;
	int y = rd.read_i32()!;
	queue_event(b, OWN_SECONDARY_ACTIVATED, b.own_item_id, 0, x, y);
	return call.reply({});
}

// ContextMenu(x, y): the host draws our menu from the DBusMenu object, so there is nothing to do here.
fn void? item_context_menu(void* context, Call* call)
{
	Reader rd = call.reader()!;
	int x = rd.read_i32()!;
	int y = rd.read_i32()!;
	return call.reply({});
}

// Scroll(delta, orientation): our icon does not react to the wheel.
fn void? item_scroll(void* context, Call* call)
{
	return call.reply({});
}

fn Value? menu_version(void* context, String path, Allocator allocator) => value::u32(DBUSMENU_VERSION);

fn Value? menu_text_direction(void* context, String path, Allocator allocator) => value::str(allocator, "ltr");

fn Value? menu_status(void* context, String path, Allocator allocator) => value::str(allocator, "normal");

// GetLayout(parent, depth, names): our menu has one level, so every depth gives the whole of it.
fn void? menu_layout(void* context, Call* call)
{
	SniBackend* b = (SniBackend*)context;
	Reader rd = call.reader()!;
	int parent = rd.read_i32()!;
	if (parent != 0) return error::INVALID_ARGUMENT~;
	return reply_layout(b, call);
}

// Build the layout in temporary memory and answer with it; the reply copies what it sends.
fn void? reply_layout(SniBackend* b, Call* call)
{
	@pool()
	{
		Value root = own_layout(b, tmem)!;
		Value[] out = { value::u32(OWN_MENU_REVISION), root };
		return call.reply(out);
	};
}

// The root `(ia{sv}av)` of our menu: entry 0 with one child per menu entry.
fn Value? own_layout(SniBackend* b, Allocator allocator)
{
	Value[] children = {};
	if (b.own.menu.len > 0)
	{
		children = alloc::new_array(allocator, Value, b.own.menu.len);
		for (sz i = 0; i < b.own.menu.len; i++)
		{
			children[i] = value::variant(allocator, own_entry(b.own.menu[i], allocator)!);
		}
	}
	Value[] root = {
		value::i32(0),
		value::array(allocator, "{sv}", {})!,
		value::array(allocator, "v", children)!,
	};
	return value::structure(allocator, root);
}

// One entry: `(ia{sv}av)` with the label, or the separator type, and no children.
fn Value? own_entry(tray::OwnMenuEntry entry, Allocator allocator)
{
	Value[] properties = {};
	if (entry.is_separator)
	{
		properties = {
			value::dict_entry(allocator, value::str(allocator, "type")!, value::variant(allocator, value::str(allocator, "separator")!))!,
		};
	}
	else
	{
		properties = {
			value::dict_entry(allocator, value::str(allocator, "label")!, value::variant(allocator, value::str(allocator, entry.label)!))!,
			value::dict_entry(allocator, value::str(allocator, "enabled")!, value::variant(allocator, value::boolean(entry.enabled)))!,
		};
	}
	Value[] fields = {
		value::i32(entry.id),
		value::array(allocator, "{sv}", properties)!,
		value::array(allocator, "v", {})!,
	};
	return value::structure(allocator, fields);
}

// Event(id, event, data, timestamp): a click on one of our entries is the only event we report.
fn void? menu_event(void* context, Call* call)
{
	SniBackend* b = (SniBackend*)context;
	Reader rd = call.reader()!;
	int id = rd.read_i32()!;
	String event = rd.read_string()!;
	rd.begin_variant()!;
	rd.skip_value()!;
	rd.end_variant()!;
	rd.read_u32()!;
	if (event == "clicked") queue_event(b, OWN_MENU_CLICKED, b.own_item_id, id, 0, 0);
	return call.reply({});
}

// AboutToShow(id): our menu never needs a new layout before a submenu opens.
fn void? menu_about_to_show(void* context, Call* call)
{
	Value[] out = { value::boolean(false) };
	return call.reply(out);
}
