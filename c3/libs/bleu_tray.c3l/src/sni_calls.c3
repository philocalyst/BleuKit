<*
 The bus calls the backend makes: properties, menu layouts, item actions and registrations.
 Each returns the reply (the caller releases it) or nothing, and fails with the bus's own error
 when the peer answers with one. Every request is built with its signature and released here.
*>
module bleu::tray::sni @feat(LINUX);
import bleu::dbus::message, bleu::dbus::marshal, bleu::error, bleu::tray, std::time;

// Get(interface, name) on an object: the reply body is one variant holding the property.
fn Message*? get_property(SniBackend* b, String destination, String path, String iface, String name)
{
	Message* request = message::method_call(b.allocator, destination, path, PROPERTIES_IFACE, "Get")!;
	defer request.release();
	Writer* w = request.body_writer("ss")!;
	w.append_string(iface)!;
	w.append_string(name)!;
	w.finish()!;
	return b.connection.call(request, CALL_TIMEOUT);
}

// An item action with two screen coordinates: Activate, SecondaryActivate or ContextMenu (ii).
fn void? call_position(SniBackend* b, ItemRecord* r, String member, int x, int y)
{
	Message* request = message::method_call(
		b.allocator,
		r.item.bus_name,
		r.item.object_path,
		r.interface_name,
		member
	)!;
	defer request.release();
	Writer* w = request.body_writer("ii")!;
	w.append_i32(x)!;
	w.append_i32(y)!;
	w.finish()!;
	Message* reply = b.connection.call(request, CALL_TIMEOUT)!;
	reply.release();
}

// Scroll(delta, orientation): the specification's orientation is "horizontal" or "vertical".
fn void? call_scroll(SniBackend* b, ItemRecord* r, int delta, bool horizontal)
{
	Message* request = message::method_call(
		b.allocator,
		r.item.bus_name,
		r.item.object_path,
		r.interface_name,
		"Scroll"
	)!;
	defer request.release();
	Writer* w = request.body_writer("is")!;
	w.append_i32(delta)!;
	w.append_string(horizontal ? "horizontal" : "vertical")!;
	w.finish()!;
	Message* reply = b.connection.call(request, CALL_TIMEOUT)!;
	reply.release();
}

// DBusMenu Event(id, "clicked", 0, timestamp): what a click on a menu entry sends.
fn void? call_menu_click(SniBackend* b, ItemRecord* r, int menu_id)
{
	Message* request = message::method_call(b.allocator, r.item.bus_name, r.item.menu_path, MENU_INTERFACE, "Event")!;
	defer request.release();
	Writer* w = request.body_writer("isvu")!;
	w.append_i32(menu_id)!;
	w.append_string("clicked")!;
	w.begin_variant("i")!;
	w.append_i32(0)!;
	w.end_variant()!;
	w.append_u32(wall_clock_millis())!;
	w.finish()!;
	Message* reply = b.connection.call(request, CALL_TIMEOUT)!;
	reply.release();
}

// DBusMenu AboutToShow(id): true when the application has changed that submenu and it must be read again.
fn bool? call_about_to_show(SniBackend* b, ItemRecord* r, int menu_id)
{
	Message* request = message::method_call(
		b.allocator,
		r.item.bus_name,
		r.item.menu_path,
		MENU_INTERFACE,
		"AboutToShow"
	)!;
	defer request.release();
	Writer* w = request.body_writer("i")!;
	w.append_i32(menu_id)!;
	w.finish()!;
	Message* reply = b.connection.call(request, CALL_TIMEOUT)!;
	defer reply.release();
	Reader rd = reply.reader()!;
	return rd.read_bool()!;
}

// DBusMenu GetLayout(parent, depth, all properties): the reply is `u(ia{sv}av)`, and the caller releases it.
fn Message*? call_layout(SniBackend* b, ItemRecord* r, int parent, int depth)
{
	Message* request = message::method_call(
		b.allocator,
		r.item.bus_name,
		r.item.menu_path,
		MENU_INTERFACE,
		"GetLayout"
	)!;
	defer request.release();
	Writer* w = request.body_writer("iias")!;
	w.append_i32(parent)!;
	w.append_i32(depth)!;
	w.begin_array("as")!;
	w.end_array()!;
	w.finish()!;
	return b.connection.call(request, CALL_TIMEOUT);
}

// The watcher's RegisterStatusNotifierItem(service): `service` is a bus name, or "bus/path".
fn void? call_register_item(SniBackend* b, String service)
{
	return call_register(b, "RegisterStatusNotifierItem", service);
}

// The watcher's RegisterStatusNotifierHost(service).
fn void? call_register_host(SniBackend* b, String service)
{
	return call_register(b, "RegisterStatusNotifierHost", service);
}

fn void? call_register(SniBackend* b, String member, String service)
{
	Message* request = message::method_call(b.allocator, WATCHER_NAME, WATCHER_PATH, WATCHER_INTERFACE, member)!;
	defer request.release();
	Writer* w = request.body_writer("s")!;
	w.append_string(service)!;
	w.finish()!;
	Message* reply = b.connection.call(request, CALL_TIMEOUT)!;
	reply.release();
}

<* Wall-clock time in milliseconds, truncated to 32 bits: the DBusMenu timestamp. *>
fn uint wall_clock_millis()
{
	long micros = (long)(Duration)time::now();
	return (uint)(micros / 1000);
}