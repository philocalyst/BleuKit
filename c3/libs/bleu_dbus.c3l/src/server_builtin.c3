<*
 The standard interfaces the server implements for every object: Peer
 (Ping, GetMachineId), Properties (Get, Set, GetAll) over the property
 descriptions, and ObjectManager's GetManagedObjects for the roots.

 Sources: D-Bus specification, "Standard Interfaces": org.freedesktop.DBus.Peer,
 org.freedesktop.DBus.Properties, org.freedesktop.DBus.ObjectManager. The
 error names for Get on a write-only property and Set on a read-only one follow
 python-dbus-next 0.2.3 (dbus_next/message_bus.py, the property handler).
*>
module bleu::dbus::server;
import bleu::error, bleu::dbus::marshal, bleu::dbus::value;
import std::io, std::collections::list;

<*
 Answers a call to org.freedesktop.DBus.Peer. Ping is answered with an empty
 reply; GetMachineId with the machine's id.
*>
fn void? peer_call(Call* c) @private
{
	if (c.member == "Ping")
	{
		if (!arguments_are(c, "")) return c.reply_error(ERROR_INVALID_ARGS, "Ping takes no arguments");
		return c.reply({});
	}
	if (c.member == "GetMachineId")
	{
		if (!arguments_are(c, "")) return c.reply_error(ERROR_INVALID_ARGS, "GetMachineId takes no arguments");
		if (try id = machine_id(tmem))
		{
			c.out_signature = "s";
			Value[] out = { value::str(tmem, id)! };
			return c.reply(out);
		}
		return c.reply_error(ERROR_FAILED, "this machine has no machine id file");
	}
	return c.reply_error(ERROR_UNKNOWN_METHOD, string::tformat("no method %s here", c.member));
}

<*
 The machine id, from the first standard file that holds one, without its line end.

 @return? error::UNAVAILABLE : "Neither /var/lib/dbus/machine-id nor /etc/machine-id can be read"
*>
fn String? machine_id(Allocator allocator) @private
{
	String[2] paths = { "/var/lib/dbus/machine-id", "/etc/machine-id" };
	foreach (path : paths)
	{
		if (try bytes = io::file::load(tmem, path))
		{
			return ((String)bytes).trim().copy(allocator);
		}
	}
	return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "no machine id file could be read")~;
}

// Routes the org.freedesktop.DBus.Properties methods of an object.
fn void? properties_call(Call* c, Target* target) @private
{
	if (c.member == "Get") return get_property(c, target);
	if (c.member == "Set") return set_property(c, target);
	if (c.member == "GetAll") return get_all_properties(c, target);
	return c.reply_error(ERROR_UNKNOWN_METHOD, string::tformat("no method %s here", c.member));
}

// Properties.Get(interface, name) -> variant. Write-only properties are not readable.
fn void? get_property(Call* c, Target* target) @private
{
	if (!arguments_are(c, "ss")) return c.reply_error(ERROR_INVALID_ARGS, "Get takes an interface and a property name");
	Reader r            = c.reader()!;
	String interface_name = r.read_string()!;
	String name         = r.read_string()!;
	Interface* i = find_interface(target.interfaces, interface_name);
	if (i == null) return c.reply_error(ERROR_UNKNOWN_INTERFACE, string::tformat("no interface %s here", interface_name));
	Property* p = find_property(i, name);
	if (p == null || p.access == WRITE) {
		return c.reply_error(ERROR_UNKNOWN_PROPERTY, string::tformat("%s has no readable property %s", interface_name, name));
	}
	Value v = p.get(p.context, c.path, tmem)!;
	c.out_signature = "v";
	Value[] out = { value::variant(tmem, v) };
	return c.reply(out);
}

// Properties.Set(interface, name, variant). A successful set announces the change, if the property does.
fn void? set_property(Call* c, Target* target) @private
{
	if (!arguments_are(c, "ssv")) return c.reply_error(ERROR_INVALID_ARGS, "Set takes an interface, a property name and a variant");
	Reader r              = c.reader()!;
	String interface_name = r.read_string()!;
	String name           = r.read_string()!;
	Value boxed           = r.read_value(tmem)!;
	Interface* i = find_interface(target.interfaces, interface_name);
	if (i == null) return c.reply_error(ERROR_UNKNOWN_INTERFACE, string::tformat("no interface %s here", interface_name));
	Property* p = find_property(i, name);
	if (p == null) return c.reply_error(ERROR_UNKNOWN_PROPERTY, string::tformat("%s has no property %s", interface_name, name));
	if (p.access == READ) return c.reply_error(ERROR_PROPERTY_READ_ONLY, string::tformat("%s is read-only", name));
	Value v = boxed.items[0];
	if (v.sig != p.signature) {
		return c.reply_error(ERROR_INVALID_ARGS, string::tformat("%s has type '%s', not '%s'", name, p.signature, v.sig));
	}
	p.set(p.context, c.path, v)!;
	announce_property(c.server, c.path, i, p)!;
	return c.reply({});
}

// Properties.GetAll(interface) -> a{sv} of the readable properties.
fn void? get_all_properties(Call* c, Target* target) @private
{
	if (!arguments_are(c, "s")) return c.reply_error(ERROR_INVALID_ARGS, "GetAll takes an interface name");
	Reader r              = c.reader()!;
	String interface_name = r.read_string()!;
	Interface* i = find_interface(target.interfaces, interface_name);
	if (i == null) return c.reply_error(ERROR_UNKNOWN_INTERFACE, string::tformat("no interface %s here", interface_name));
	c.out_signature = "a{sv}";
	Value props = readable_properties(tmem, c.path, i)!;
	Value[] out = { props };
	return c.reply(out);
}

<*
 The readable properties of `i` for the object at `path`, as an `a{sv}`. Each value
 is a variant holding the property's own type. Allocated in `allocator`.
*>
fn Value? readable_properties(Allocator allocator, String path, Interface* i) @private
{
	List{Value} entries;
	entries.init(allocator);
	defer entries.free();
	for (sz k = 0; k < i.properties.len; k++)
	{
		Property* p = &i.properties[k];
		if (p.access == WRITE) continue;
		Value v   = p.get(p.context, path, allocator)!;
		Value key = value::str(allocator, p.name)!;
		entries.push(value::dict_entry(allocator, key, value::variant(allocator, v))!);
	}
	return value::array(allocator, "{sv}", entries.to_aligned_array(allocator))!;
}

// ObjectManager.GetManagedObjects() -> a{oa{sa{sv}}}, for a root's objects below it.
fn void? managed_objects_call(Call* c) @private
{
	if (c.member != "GetManagedObjects") return c.reply_error(ERROR_UNKNOWN_METHOD, string::tformat("no method %s here", c.member));
	if (!arguments_are(c, "")) return c.reply_error(ERROR_INVALID_ARGS, "GetManagedObjects takes no arguments");
	c.out_signature = "a{oa{sa{sv}}}";
	Value objects = managed_objects(c.server, tmem, c.path)!;
	Value[] out = { objects };
	return c.reply(out);
}

<*
 Every object below `root` that implements an interface, with its interfaces and
 their readable properties, as `a{oa{sa{sv}}}`. Allocated in `allocator`.
*>
fn Value? managed_objects(ObjectServer* server, Allocator allocator, String root) @private
{
	List{Value} entries;
	entries.init(allocator);
	defer entries.free();
	foreach (e : server.exports)
	{
		if (e.interfaces.len == 0 || !is_below(e.path.str_view(), root)) continue;
		Value key    = value::path(allocator, e.path.str_view())!;
		Value ifaces = interfaces_value(allocator, e.path.str_view(), e.interfaces)!;
		entries.push(value::dict_entry(allocator, key, ifaces)!);
	}
	return value::array(allocator, "{oa{sa{sv}}}", entries.to_aligned_array(allocator))!;
}

<*
 The interfaces of the object at `path` with their readable properties, as `a{sa{sv}}`.
 Used by GetManagedObjects and InterfacesAdded. Allocated in `allocator`.
*>
fn Value? interfaces_value(Allocator allocator, String path, Interface[] interfaces) @private
{
	List{Value} entries;
	entries.init(allocator);
	defer entries.free();
	for (sz k = 0; k < interfaces.len; k++)
	{
		Interface* i = &interfaces[k];
		Value key    = value::str(allocator, i.name)!;
		Value props  = readable_properties(allocator, path, i)!;
		entries.push(value::dict_entry(allocator, key, props)!);
	}
	return value::array(allocator, "{sa{sv}}", entries.to_aligned_array(allocator))!;
}

// True when the call's body has the signature `sig`.
fn bool arguments_are(Call* c, String sig) @private => incoming_signature(c.message) == sig;
