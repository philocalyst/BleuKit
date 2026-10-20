<*
 Signals the server sends: the signals an interface declares, PropertiesChanged,
 and InterfacesAdded and InterfacesRemoved for ObjectManager roots.

 Sources: D-Bus specification, "Standard Interfaces": org.freedesktop.DBus.Properties
 (PropertiesChanged, EmitsChangedSignal) and org.freedesktop.DBus.ObjectManager
 (InterfacesAdded, InterfacesRemoved).
*>
module bleu::dbus::server;
import bleu::error, bleu::dbus::message, bleu::dbus::value;
import std::collections::list;

<* Member name of the signal that announces changed properties. *>
const SIGNAL_PROPERTIES_CHANGED = "PropertiesChanged";

<* Member name of the signal that announces a new object's interfaces. *>
const SIGNAL_INTERFACES_ADDED = "InterfacesAdded";

<* Member name of the signal that announces the interfaces an object lost. *>
const SIGNAL_INTERFACES_REMOVED = "InterfacesRemoved";

<*
 Emit a signal that interface `interface_name` of the object at `path` declares.
 `args` must follow the signal's signature.

 @param args : "The arguments, in order"
 @return? NOT_FOUND : "No object, interface or signal of that name is there"
 @return? error::INVALID_ARGUMENT : "The arguments do not match the signature"
 @return? error::DISCONNECTED : "The signal could not be sent"
*>
fn void? ObjectServer.emit_signal(&self, String path, String interface_name, String member, Value[] args)
{
	Target target = self.find_target(path);
	if (!target.found) return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no object at %s", path)~;
	Interface* i = find_interface(target.interfaces, interface_name);
	if (i == null) return error::raise(
		NOT_FOUND,
		error::Domain.INTERNAL,
		0,
		"no interface %s at %s",
		interface_name,
		path
	)~;
	Signal* s = find_signal(i, member);
	if (s == null) return error::raise(
		NOT_FOUND,
		error::Domain.INTERNAL,
		0,
		"no signal %s in %s",
		member,
		interface_name
	)~;
	return send_signal(self, path, interface_name, member, s.signature, args);
}

<*
 Announce that properties of `interface_name` at `path` changed. Each property
 named is read with its getter, so the announcement carries the current state:
 `EMITS_CHANGED` properties send their value, `INVALIDATES` ones are named only.

 @param names : "The properties that changed"
 @return? NOT_FOUND : "No object, interface or property of that name is there"
 @return? error::INVALID_ARGUMENT : "A property is declared NEVER or CONST, so it has no announcement"
 @return? error::DISCONNECTED : "The signal could not be sent"
*>
fn void? ObjectServer.emit_properties_changed(&self, String path, String interface_name, String[] names)
{
	@pool()
	{
		Target target = self.find_target(path);
		if (!target.found) return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no object at %s", path)~;
		Interface* i = find_interface(target.interfaces, interface_name);
		if (i == null) return error::raise(
			NOT_FOUND,
			error::Domain.INTERNAL,
			0,
			"no interface %s at %s",
			interface_name,
			path
		)~;
		List{Value} changed;
		changed.init(tmem);
		List{Value} invalidated;
		invalidated.init(tmem);
		foreach (name : names)
		{
			Property* p = find_property(i, name);
			if (p == null) return error::raise(
				NOT_FOUND,
				error::Domain.INTERNAL,
				0,
				"no property %s in %s",
				name,
				interface_name
			)~;
			switch (p.changes)
			{
				case NEVER:
				case CONST:
					return error::raise(
						error::INVALID_ARGUMENT,
						error::Domain.INTERNAL,
						0,
						"property %s does not announce changes",
						name
					)~;
				case INVALIDATES:
					invalidated.push(value::str(tmem, name)!);
				case EMITS_CHANGED:
					Value v = p.get(p.context, path, tmem)!;
					changed.push(value::dict_entry(tmem, value::str(tmem, name)!, value::variant(tmem, v))!);
			}
		}
		Value[] body = {
			value::str(tmem, interface_name)!,
			value::array(tmem, "{sv}", changed.to_aligned_array(tmem))!,
			value::array(tmem, "s", invalidated.to_aligned_array(tmem))!,
		};
		return send_signal(self, path, INTERFACE_PROPERTIES, SIGNAL_PROPERTIES_CHANGED, "sa{sv}as", body);
	};
}

// Announces a property that a Set has just changed, when its rule says changes are announced.
fn void? announce_property(ObjectServer* server, String path, Interface* i, Property* p) @private
{
	if (p.changes != EMITS_CHANGED && p.changes != INVALIDATES) return;
	String[1] one  = { p.name };
	String[] names = one[..];
	return server.emit_properties_changed(path, i.name, names);
}

// Sends InterfacesAdded for the object `e` on every ObjectManager root above it.
fn void? ObjectServer.announce_added(&self, Export* e)
{
	@pool()
	{
		foreach (root : self.exports)
		{
			if (!root.manager || !is_below(e.path.str_view(), root.path.str_view())) continue;
			Value[] body = {
				value::path(tmem, e.path.str_view())!,
				interfaces_value(tmem, e.path.str_view(), e.interfaces)!,
			};
			send_signal(
				self,
				root.path.str_view(),
				INTERFACE_OBJECT_MANAGER,
				SIGNAL_INTERFACES_ADDED,
				"oa{sa{sv}}",
				body
			)!;
		}
	};
}

// Sends InterfacesRemoved for the object `e` on every ObjectManager root above it.
fn void? ObjectServer.announce_removed(&self, Export* e)
{
	if (e.interfaces.len == 0) return;
	@pool()
	{
		foreach (root : self.exports)
		{
			if (!root.manager || !is_below(e.path.str_view(), root.path.str_view())) continue;
			List{Value} names;
			names.init(tmem);
			for (sz k = 0; k < e.interfaces.len; k++) names.push(value::str(tmem, e.interfaces[k].name)!);
			Value[] body = {
				value::path(tmem, e.path.str_view())!,
				value::array(tmem, "s", names.to_aligned_array(tmem))!,
			};
			send_signal(self, root.path.str_view(), INTERFACE_OBJECT_MANAGER, SIGNAL_INTERFACES_REMOVED, "oas", body)!;
		}
	};
}

// Builds a signal from `path` whose body is `args` for `signature`, and sends it.
fn void? send_signal(
	ObjectServer* server,
	String path,
	String interface_name,
	String member,
	String signature,
	Value[] args
) @private
{
	Message* m = message::signal(server.allocator, path, interface_name, member)!;
	defer m.release();
	int[] no_fds;
	fill_body(m, signature, args, no_fds)!;
	return send_message(server, m);
}