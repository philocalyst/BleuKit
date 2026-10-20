<*
 Server-side object export: the description of an interface, as data.

 An `Interface` lists its methods, properties and signals, with the signatures
 and argument names that the introspection XML needs, and with the handler
 functions that serve them. The tables are referenced, not copied: they must
 outlive the export. Descriptions are checked once, when they are exported
 (`validate_interface`), so the dispatch code never meets a malformed one.

 The standard interfaces (Peer, Introspectable, Properties, ObjectManager) are
 not described here: the server implements them for every object.
*>
module bleu::dbus::server;
import bleu::error, bleu::dbus::signature, bleu::dbus::names, bleu::dbus::value;

<*
 The access a property allows, as the specification's `access` attribute.
*>
enum PropertyAccess : char
{
	READ,       // Get works, Set is refused
	WRITE,      // Set works, Get is refused
	READ_WRITE, // both work
}

<*
 How a change of a property is announced, from the specification's
 `org.freedesktop.DBus.Property.EmitsChangedSignal` annotation.

 `EMITS_CHANGED` sends the new value in PropertiesChanged. `INVALIDATES` names
 the property in PropertiesChanged without its value, so listeners fetch it.
 `CONST` means the value never changes after the object is exported. `NEVER`
 means changes are not announced.
*>
enum ChangeSignal : char
{
	EMITS_CHANGED,
	INVALIDATES,
	CONST,
	NEVER,
}

<*
 Serves a method call. Read the arguments with `call.reader()`, then answer
 with `call.reply`, `call.reply_error`, or `call.defer_reply`. Returning a fault
 without having answered answers the call with the D-Bus error that the fault
 stands for (see `error_name_for`).
*>
alias MethodHandler = fn void?(void* context, Call* call);

<*
 Returns the current value of a property, allocated in `allocator`. `path` is the
 object the property belongs to (it differs per object for fallback paths).
*>
alias PropertyGetter = fn Value?(void* context, String path, Allocator allocator);

<*
 Stores a new value of a property. `value` is valid only during the call.
*>
alias PropertySetter = fn void?(void* context, String path, Value value);

<*
 A method of an interface.

 `in_signature` and `out_signature` are the complete signatures of the
 arguments and the results ("ss", "" for none). `in_names` and `out_names`
 are the names of those arguments in order, for the introspection XML; they
 may be empty, or have exactly one name per complete type.
*>
struct Method
{
	String name;
	String in_signature;
	String out_signature;
	String[] in_names;
	String[] out_names;
	MethodHandler handler;
	void* context;
}

<*
 A readable and/or writable property. `signature` is one complete type.
 `get` is required when the property can be read, `set` when it can be written.
 A write-only property cannot announce its value, so it must use `NEVER`.
*>
struct Property
{
	String name;
	String signature;
	PropertyAccess access;
	ChangeSignal changes;
	PropertyGetter get;
	PropertySetter set;
	void* context;
}

<* A signal an interface emits. `signature` is the complete signature of its arguments. *>
struct Signal
{
	String name;
	String signature;
	String[] arg_names;
}

<*
 An interface: its name and the members it has. Exported objects list the
 interfaces they implement.
*>
struct Interface
{
	String name;
	Method[] methods;
	Property[] properties;
	Signal[] signals;
}

<*
 Check an interface description: names, signatures, argument names, the handlers
 each access needs, and the rules for announcing changes. Duplicate members are refused.

 @return? error::INVALID_ARGUMENT : "The description is malformed; the message says where"
*>
fn void? validate_interface(Interface* i)
{
	if (!names::is_interface(i.name)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "interface name '%s' is not valid", i.name)~;
	for (sz k = 0; k < i.methods.len; k++)
	{
		Method* m = &i.methods[k];
		if (!names::is_member(m.name)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "method name '%s' is not valid", m.name)~;
		if (!signature::valid(m.in_signature) || !signature::valid(m.out_signature))
		{
			return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "method '%s' has an invalid signature", m.name)~;
		}
		if (!m.handler) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "method '%s' has no handler", m.name)~;
		if (!arg_names_fit(m.in_names, m.in_signature) || !arg_names_fit(m.out_names, m.out_signature))
		{
			return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "method '%s' has the wrong number of argument names", m.name)~;
		}
		if (find_method_index(i, m.name, k) >= 0) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "method '%s' is declared twice", m.name)~;
	}
	for (sz k = 0; k < i.properties.len; k++) validate_property(i, k)!;
	for (sz k = 0; k < i.signals.len; k++)
	{
		Signal* s = &i.signals[k];
		if (!names::is_member(s.name) || !signature::valid(s.signature)) {
			return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "signal '%s' is not valid", s.name)~;
		}
		if (!arg_names_fit(s.arg_names, s.signature)) {
			return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "signal '%s' has the wrong number of argument names", s.name)~;
		}
	}
}

// Checks one property of `i`: its name and type, the handlers its access needs, and its announcement rule.
fn void? validate_property(Interface* i, sz index) @private
{
	Property* p = &i.properties[index];
	if (!names::is_member(p.name) || !signature::is_single(p.signature)) {
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "property '%s' has no valid single type", p.name)~;
	}
	if (p.access != WRITE && !p.get) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "property '%s' can be read but has no getter", p.name)~;
	if (p.access != READ && !p.set) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "property '%s' can be written but has no setter", p.name)~;
	if (p.access == WRITE && (p.changes == EMITS_CHANGED || p.changes == INVALIDATES)) {
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "write-only property '%s' cannot announce its value", p.name)~;
	}
	if (p.changes == CONST && p.access != READ) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "constant property '%s' must be read-only", p.name)~;
	if (find_property_index(i, p.name, index) >= 0) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "property '%s' is declared twice", p.name)~;
}

// True when `names` is empty, or has one name for each complete type of `sig`.
fn bool arg_names_fit(String[] names, String sig) @private
{
	if (names.len == 0) return true;
	return (sz)count_types(sig) == names.len;
}

// The number of complete types in a valid signature.
fn usz count_types(String sig) @private
{
	usz count = 0;
	TypeIterator it = signature::iterate(sig);
	while (it.has_next())
	{
		it.next()!!;
		count++;
	}
	return count;
}

// Index of the method called `name` in `i`, skipping index `except`, or -1.
fn sz find_method_index(Interface* i, String name, sz except) @private
{
	for (sz k = 0; k < i.methods.len; k++)
	{
		if (k != except && i.methods[k].name == name) return k;
	}
	return -1;
}

// Index of the property called `name` in `i`, skipping index `except`, or -1.
fn sz find_property_index(Interface* i, String name, sz except) @private
{
	for (sz k = 0; k < i.properties.len; k++)
	{
		if (k != except && i.properties[k].name == name) return k;
	}
	return -1;
}

// The method called `name`, or null.
fn Method* find_method(Interface* i, String name)
{
	sz k = find_method_index(i, name, -1);
	return k < 0 ? null : &i.methods[k];
}

// The property called `name`, or null.
fn Property* find_property(Interface* i, String name)
{
	sz k = find_property_index(i, name, -1);
	return k < 0 ? null : &i.properties[k];
}

// The signal called `name`, or null.
fn Signal* find_signal(Interface* i, String name)
{
	for (sz k = 0; k < i.signals.len; k++)
	{
		if (i.signals[k].name == name) return &i.signals[k];
	}
	return null;
}

// The interface called `name` in `list`, or null.
fn Interface* find_interface(Interface[] list, String name)
{
	for (sz k = 0; k < list.len; k++)
	{
		if (list[k].name == name) return &list[k];
	}
	return null;
}
