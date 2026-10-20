<*
 Proxies: the methods of one remote object, as calls and as typed values.

 A `Proxy` names a destination (a bus name), an object path and an interface, and
 offers the standard calls on them: `org.freedesktop.DBus.Properties` (Get, Set,
 GetAll), `org.freedesktop.DBus.ObjectManager` (GetManagedObjects) and
 `org.freedesktop.DBus.Introspectable` (Introspect). It also subscribes to the
 signals those interfaces emit (PropertiesChanged, InterfacesAdded,
 InterfacesRemoved) and hands their arguments over parsed.

 Results are values built from the caller's allocator (see `bleu::dbus::value`).
 Every call here blocks, as `Connection.call` does; use `new_call` with
 `Connection.call_async` for non-blocking calls.

 Sources: D-Bus specification, "Standard Interfaces": org.freedesktop.DBus.Properties
 (Get, Set, GetAll and the PropertiesChanged signal with its invalidated list),
 org.freedesktop.DBus.ObjectManager (GetManagedObjects, InterfacesAdded,
 InterfacesRemoved), and org.freedesktop.DBus.Introspectable.Introspect.
*>
module bleu::dbus::proxy;
import bleu::error, bleu::dbus::connection, bleu::dbus::match, bleu::dbus::message, bleu::dbus::marshal, bleu::dbus::names, bleu::dbus::value;
import std::collections::list, std::time;

<* Interface of the property accessors. *>
const PROPERTIES_INTERFACE = "org.freedesktop.DBus.Properties";

<* Interface of GetManagedObjects and of the object-tree signals. *>
const OBJECT_MANAGER_INTERFACE = "org.freedesktop.DBus.ObjectManager";

<* Interface of Introspect. *>
const INTROSPECTABLE_INTERFACE = "org.freedesktop.DBus.Introspectable";

<* The PropertiesChanged signal. *>
const PROPERTIES_CHANGED = "PropertiesChanged";

<* The object-tree signals. *>
const INTERFACES_ADDED   = "InterfacesAdded";
const INTERFACES_REMOVED = "InterfacesRemoved";

<*
 One remote object: the destination it lives on, its path, and the interface
 the calls are made on. The connection must outlive the proxy.
*>
struct Proxy
{
	Connection* connection;
	String destination;
	String path;
	String interface_name;
}

<*
 A proxy for `interface_name` on `path` at `destination`.

 @return? error::INVALID_ARGUMENT : "A name or the path is not valid"
*>
fn Proxy? for_object(Connection* connection, String destination, String path, String interface_name)
{
	if (!names::is_bus_name(destination) || !names::is_object_path(path) || !names::is_interface(interface_name))
	{
		return error::INVALID_ARGUMENT~;
	}
	return { .connection = connection, .destination = destination, .path = path, .interface_name = interface_name };
}

<*
 A METHOD_CALL to `member` on this proxy's interface, ready for arguments.
 Write them with `body_writer`, then send it with `Connection.call`.

 @param allocator : "Allocator for the message, which the caller releases"
*>
fn Message*? Proxy.new_call(&self, Allocator allocator, String member)
{
	return message::method_call(allocator, self.destination, self.path, self.interface_name, member);
}

<*
 The value of a property, unwrapped from its variant.

 @param allocator : "Allocator for the returned value"
 @return? NOT_FOUND : "The object has no such property (UnknownProperty)"
 @return? error::PERMISSION_DENIED : "The property is not readable by this caller"
*>
fn Value? Proxy.get_property(&self, String name, Allocator allocator, Duration timeout = time::ms(25000))
{
	Message* call = property_call(self, "Get")!;
	defer call.release();
	Writer* w = call.body_writer("ss")!;
	w.append_string(self.interface_name)!;
	w.append_string(name)!;
	Message* reply = self.connection.call(call, timeout)!;
	defer reply.release();
	Reader r = reply.reader()!;
	return r.read_value(allocator)!.unwrap();
}

<*
 Set a property to `value`. The value's signature is the property's type.

 @return? error::PERMISSION_DENIED : "The property is read-only, or the caller may not set it"
 @return? error::INVALID_ARGUMENT : "The value does not have the property's type (InvalidArgs)"
*>
fn void? Proxy.set_property(&self, String name, Value value, Duration timeout = time::ms(25000))
{
	Message* call = property_call(self, "Set")!;
	defer call.release();
	Writer* w = call.body_writer("ssv")!;
	w.append_string(self.interface_name)!;
	w.append_string(name)!;
	w.begin_variant(value.sig)!;
	w.append_value(value)!;
	w.end_variant()!;
	Message* reply = self.connection.call(call, timeout)!;
	reply.release();
}

<*
 Every readable property of this interface, as an `a{sv}`.

 @param allocator : "Allocator for the returned value"
*>
fn Value? Proxy.get_all_properties(&self, Allocator allocator, Duration timeout = time::ms(25000))
{
	Message* call = property_call(self, "GetAll")!;
	defer call.release();
	call.body_writer("s")!.append_string(self.interface_name)!;
	Message* reply = self.connection.call(call, timeout)!;
	defer reply.release();
	return reply.reader()!.read_value(allocator)!;
}

<* A string property. @return? error::INVALID_ARGUMENT : "The property is not a string" *>
fn String? Proxy.get_string(&self, String name, Allocator allocator, Duration timeout = time::ms(25000))
{
	Value v = self.get_property(name, allocator, timeout)!;
	return v.as_string()!;
}

<* A UINT32 property. @return? error::INVALID_ARGUMENT : "The property is not a uint32" *>
fn uint? Proxy.get_u32(&self, String name, Duration timeout = time::ms(25000))
{
	@pool()
	{
		Value v = self.get_property(name, tmem, timeout)!;
		return v.as_u32()!;
	};
}

<* An INT32 property. @return? error::INVALID_ARGUMENT : "The property is not an int32" *>
fn int? Proxy.get_i32(&self, String name, Duration timeout = time::ms(25000))
{
	@pool()
	{
		Value v = self.get_property(name, tmem, timeout)!;
		return v.as_i32()!;
	};
}

<* A BOOLEAN property. @return? error::INVALID_ARGUMENT : "The property is not a boolean" *>
fn bool? Proxy.get_bool(&self, String name, Duration timeout = time::ms(25000))
{
	@pool()
	{
		Value v = self.get_property(name, tmem, timeout)!;
		return v.as_bool()!;
	};
}

<*
 The object tree under this proxy's path, as `a{oa{sa{sv}}}`: every object,
 its interfaces, and their properties (ObjectManager.GetManagedObjects).
 The proxy's path must be an ObjectManager's.

 @param allocator : "Allocator for the returned value"
*>
fn Value? Proxy.get_managed_objects(&self, Allocator allocator, Duration timeout = time::ms(25000))
{
	Message* call = message::method_call(
		self.connection.allocator,
		self.destination,
		self.path,
		OBJECT_MANAGER_INTERFACE,
		"GetManagedObjects"
	)!;
	defer call.release();
	Message* reply = self.connection.call(call, timeout)!;
	defer reply.release();
	return reply.reader()!.read_value(allocator)!;
}

<*
 The XML description of the object: its interfaces, methods, signals,
 properties and child nodes (Introspectable.Introspect).

 @param allocator : "Allocator for the returned text"
*>
fn String? Proxy.introspect(&self, Allocator allocator, Duration timeout = time::ms(25000))
{
	Message* call = message::method_call(
		allocator,
		self.destination,
		self.path,
		INTROSPECTABLE_INTERFACE,
		"Introspect"
	)!;
	defer call.release();
	Message* reply = self.connection.call(call, timeout)!;
	defer reply.release();
	return reply.reader()!.read_string()!.copy(allocator);
}

<*
 A property change, as delivered by `watch_properties`. `changed` is an
 `a{sv}` of the new values; `invalidated` lists the properties that changed
 without a new value. All of it is valid only during the handler call.
*>
struct PropertyChange
{
	String path;
	String interface_name;
	Value changed;
	String[] invalidated;
}

<* Called for each PropertiesChanged signal that the subscription accepts. *>
alias PropertyHandler = fn void(void* context, PropertyChange* change);

<*
 An object-tree change, as delivered by `watch_objects`. When `added`, `path`
 gained `interfaces` (an `a{sa{sv}}`); otherwise `path` lost the interfaces in
 `removed`. Valid only during the handler call.
*>
struct ObjectChange
{
	bool added;
	String path;
	Value interfaces;
	String[] removed;
}

<* Called for each InterfacesAdded or InterfacesRemoved signal. *>
alias ObjectHandler = fn void(void* context, ObjectChange* change);

// What a property watch needs when a signal arrives.
struct PropertyWatch
{
	PropertyHandler handler;
	void* context;
}

// What an object watch needs when a signal arrives.
struct ObjectWatch
{
	ObjectHandler handler;
	void* context;
}

<*
 Call `handler` for each PropertiesChanged signal from this proxy's destination
 at its path, or, with `subtree`, at any path beneath it.

 @return "Identifier for `Connection.unsubscribe`"
*>
fn SubscriptionId? Proxy.watch_properties(&self, PropertyHandler handler, void* context, bool subtree = false)
{
	match::Match rule    = signal_rule(self, PROPERTIES_INTERFACE, PROPERTIES_CHANGED, subtree);
	PropertyWatch* watch = alloc::new(self.connection.allocator, PropertyWatch);
	*watch = { .handler = handler, .context = context };
	return self.connection.subscribe(rule, &property_signal, watch, watch);
}

<*
 Call `handler` for each InterfacesAdded and InterfacesRemoved signal under
 this proxy's path: the object tree below an ObjectManager.

 @return "Identifier for `Connection.unsubscribe`"
*>
fn SubscriptionId? Proxy.watch_objects(&self, ObjectHandler handler, void* context)
{
	match::Match rule  = signal_rule(self, OBJECT_MANAGER_INTERFACE, "", true);
	ObjectWatch* watch = alloc::new(self.connection.allocator, ObjectWatch);
	*watch = { .handler = handler, .context = context };
	return self.connection.subscribe(rule, &object_signal, watch, watch);
}

// The method call on the Properties interface, with the method name `member`.
fn Message*? property_call(Proxy* self, String member) @private
{
	return message::method_call(self.connection.allocator, self.destination, self.path, PROPERTIES_INTERFACE, member);
}

// A match rule for a signal of `interface_name` from this destination, on this path or below it.
// An empty `member` matches every signal of the interface. Names were checked by `for_object`.
fn match::Match signal_rule(Proxy* self, String interface_name, String member, bool subtree) @private
{
	match::Match rule;
	rule.init(self.connection.allocator);
	rule.with_type(MessageType.SIGNAL)!!;
	rule.with_sender(self.destination)!!;
	rule.with_interface(interface_name)!!;
	if (member.len > 0) rule.with_member(member)!!;
	if (subtree)
	{
		rule.with_path_namespace(self.path)!!;
	}
	else
	{
		rule.with_path(self.path)!!;
	}
	return rule;
}

// Signal handler: parses PropertiesChanged and hands it to the watcher.
fn void property_signal(void* context, Message* signal) @private
{
	PropertyWatch* watch = (PropertyWatch*)context;
	// A signal that does not parse is not ours to act on; it is skipped.
	if (try r = signal.reader())
	{
		if (try interface_name = r.read_string())
		{
			if (try changed = r.read_value(&signal.storage))
			{
				if (try invalid = r.read_value(&signal.storage))
				{
					if (try invalidated = strings_of(invalid, &signal.storage))
					{
						PropertyChange change = {
							.path = signal.path,
							.interface_name = interface_name,
							.changed = changed,
							.invalidated = invalidated
						};
						watch.handler(watch.context, &change);
					}
				}
			}
		}
	}
}

// Signal handler: parses InterfacesAdded and InterfacesRemoved and hands them to the watcher.
fn void object_signal(void* context, Message* signal) @private
{
	ObjectWatch* watch = (ObjectWatch*)context;
	if (try r = signal.reader())
	{
		if (try path = r.read_object_path())
		{
			if (signal.member == INTERFACES_ADDED)
			{
				if (try interfaces = r.read_value(&signal.storage))
				{
					ObjectChange change = { .added = true, .path = path, .interfaces = interfaces };
					watch.handler(watch.context, &change);
				}
				return;
			}
			if (signal.member == INTERFACES_REMOVED)
			{
				if (try removed = r.read_value(&signal.storage))
				{
					if (try names = strings_of(removed, &signal.storage))
					{
						ObjectChange change = { .added = false, .path = path, .removed = names };
						watch.handler(watch.context, &change);
					}
				}
			}
		}
	}
}

// The strings of an `as` value, copied into `allocator`.
fn String[]? strings_of(Value list, Allocator allocator) @private
{
	String[] out = alloc::new_array(allocator, String, (sz)list.count());
	for (usz i = 0; i < out.len; i++) out[i] = list.at(i)!.as_string()!;
	return out;
}