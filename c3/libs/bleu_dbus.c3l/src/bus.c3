<*
 The message bus daemon's own interface, as methods of `Connection`: owning
 well-known names, asking the bus to route signals to us (match rules), tracking
 who owns a name, and starting services.

 Sources: D-Bus specification, "Message Bus Specification": RequestName (flags
 and reply codes), ReleaseName, AddMatch and RemoveMatch, ListNames, NameHasOwner,
 GetNameOwner, StartServiceByName, and the NameOwnerChanged signal. The numeric
 reply codes are the ones the specification lists (1 to 4, and 1 to 3, and 1 to 2).
*>
module bleu::dbus::bus;
import bleu::error, bleu::dbus::connection, bleu::dbus::match, bleu::dbus::message,
	bleu::dbus::marshal, bleu::dbus::names, bleu::dbus::value;

<* RequestName flag: other connections may take the name from this one. *>
const uint NAME_ALLOW_REPLACEMENT = 0x1;

<* RequestName flag: take the name from its current owner if that owner allows it. *>
const uint NAME_REPLACE_EXISTING = 0x2;

<* RequestName flag: do not wait in the queue for the name. *>
const uint NAME_DO_NOT_QUEUE = 0x4;

<*
 The answer to RequestName. The values are the specification's reply codes.
*>
enum NameReply : char
{
	UNKNOWN_REPLY,
	PRIMARY_OWNER,    // this connection now owns the name
	IN_QUEUE,         // the name is owned elsewhere; we wait our turn
	EXISTS,           // the name is owned elsewhere and we did not queue
	ALREADY_OWNER,    // this connection already owned it
}

<* The answer to ReleaseName. The values are the specification's reply codes. *>
enum ReleaseReply : char
{
	UNKNOWN_REPLY,
	RELEASED,         // the name was released
	NON_EXISTENT,     // nobody owns the name
	NOT_OWNER,        // someone else owns it
}

<* The answer to StartServiceByName. The values are the specification's reply codes. *>
enum StartReply : char
{
	UNKNOWN_REPLY,
	SUCCESS,          // the service was started
	ALREADY_RUNNING,  // the name already had an owner
}

<* Name of the signal the bus sends when a name changes owner. *>
const NAME_OWNER_CHANGED = "NameOwnerChanged";

<*
 Ask the bus to give this connection `name`.

 @param flags : "Any of NAME_ALLOW_REPLACEMENT, NAME_REPLACE_EXISTING, NAME_DO_NOT_QUEUE"
 @return? error::INVALID_ARGUMENT : "Not a well-known bus name"
*>
fn NameReply? Connection.request_name(&self, String name, uint flags)
{
	if (!names::is_bus_name(name) || name[0] == ':') return error::INVALID_ARGUMENT~;
	Message* call = bus_method(self, "RequestName")!;
	defer call.release();
	Writer* w = call.body_writer("su")!;
	w.append_string(name)!;
	w.append_u32(flags)!;
	Message* reply = self.call(call)!;
	defer reply.release();
	uint code = reply.reader()!.read_u32()!;
	return (NameReply)(char)code;
}

<*
 Give up a well-known name this connection owns.

 @return? error::INVALID_ARGUMENT : "Not a well-known bus name"
*>
fn ReleaseReply? Connection.release_name(&self, String name)
{
	if (!names::is_bus_name(name) || name[0] == ':') return error::INVALID_ARGUMENT~;
	Message* call = bus_method(self, "ReleaseName")!;
	defer call.release();
	call.body_writer("s")!.append_string(name)!;
	Message* reply = self.call(call)!;
	defer reply.release();
	uint code = reply.reader()!.read_u32()!;
	return (ReleaseReply)(char)code;
}

<*
 Register `handler` for the messages `rule` accepts, and ask the bus to send
 them to this connection. The rule is consumed: do not free it afterwards.
 A well-known sender is tracked, so the connection knows its owner.

 @param context : "Passed to the handler"
 @return "Identifier for `unsubscribe`"
 @return? error::BACKEND_FAILURE : "The bus refused the match rule (see error::last())"
*>
fn SubscriptionId? Connection.subscribe(&self, match::Match rule, SignalHandler handler, void* context, void* owned = null)
{
	if (catch err = add_match(self, rule.rule_text())) {
		rule.free();
		if (owned != null) alloc::free(self.allocator, owned);
		return err~;
	}
	if (rule.sender.len > 0) track_sender(self, rule.sender)!;
	return self.add_subscription(rule, handler, context, owned);
}

<*
 Stop a subscription: the bus is asked to stop sending its messages, and no
 further handler calls are made for it.

 @return? NOT_FOUND : "No active subscription has this identifier"
*>
fn void? Connection.unsubscribe(&self, SubscriptionId id)
{
	Subscription* s = self.subscription(id)!;
	String rule_text = s.rule.rule_text();
	self.deactivate(id);
	remove_match(self, rule_text)!;
}

<*
 Call `handler` for every change of owner of `name`. The handler receives the
 NameOwnerChanged signal; `name_owner_change` reads its three arguments.

 @return? error::INVALID_ARGUMENT : "Not a well-known bus name"
*>
fn SubscriptionId? Connection.watch_name(&self, String name, SignalHandler handler, void* context)
{
	if (!names::is_bus_name(name) || name[0] == ':') return error::INVALID_ARGUMENT~;
	match::Match rule;
	rule.init(self.allocator);
	rule.with_type(MessageType.SIGNAL)!;
	rule.with_sender(connection::BUS_NAME)!;
	rule.with_interface(connection::BUS_INTERFACE)!;
	rule.with_member(NAME_OWNER_CHANGED)!;
	rule.with_arg(0, name)!;
	return self.subscribe(rule, handler, context);
}

<*
 The arguments of a NameOwnerChanged signal: the name, its old owner and its
 new owner (empty when there is none). The strings are valid while `signal` is.

 @return? error::PROTOCOL : "The message is not a NameOwnerChanged signal"
*>
fn void? name_owner_change(Message* signal, String* name, String* old_owner, String* new_owner)
{
	if (signal.member != NAME_OWNER_CHANGED || signal.signature != "sss") return error::PROTOCOL~;
	Reader r = signal.reader()!;
	*name = r.read_string()!;
	*old_owner = r.read_string()!;
	*new_owner = r.read_string()!;
}

<* Every name on the bus, unique and well-known, copied into `allocator`. *>
fn String[]? Connection.list_names(&self, Allocator allocator)
{
	Message* call = bus_method(self, "ListNames")!;
	defer call.release();
	Message* reply = self.call(call)!;
	defer reply.release();
	return string_array(reply.reader()!, allocator);
}

<* Whether some connection currently owns `name`. *>
fn bool? Connection.name_has_owner(&self, String name)
{
	Message* call = bus_method(self, "NameHasOwner")!;
	defer call.release();
	call.body_writer("s")!.append_string(name)!;
	Message* reply = self.call(call)!;
	defer reply.release();
	return reply.reader()!.read_bool()!;
}

<*
 The unique name that owns `name`, copied into `allocator`.

 @return? error::UNAVAILABLE : "No connection owns the name (NameHasNoOwner), or the bus does not know it"
*>
fn String? Connection.get_name_owner(&self, String name, Allocator allocator)
{
	Message* call = bus_method(self, "GetNameOwner")!;
	defer call.release();
	call.body_writer("s")!.append_string(name)!;
	Message* reply = self.call(call)!;
	defer reply.release();
	return reply.reader()!.read_string()!.copy(allocator);
}

<*
 Start the service that activates `name`, if it is not running.

 @return? error::INVALID_ARGUMENT : "Not a well-known bus name"
*>
fn StartReply? Connection.start_service_by_name(&self, String name)
{
	if (!names::is_bus_name(name) || name[0] == ':') return error::INVALID_ARGUMENT~;
	Message* call = bus_method(self, "StartServiceByName")!;
	defer call.release();
	Writer* w = call.body_writer("su")!;
	w.append_string(name)!;
	w.append_u32(0)!;
	Message* reply = self.call(call)!;
	defer reply.release();
	uint code = reply.reader()!.read_u32()!;
	return (StartReply)(char)code;
}

// A METHOD_CALL to a member of org.freedesktop.DBus on the bus daemon.
fn Message*? bus_method(Connection* c, String member) @private
{
	return message::method_call(c.allocator, connection::BUS_NAME, connection::BUS_PATH, connection::BUS_INTERFACE, member);
}

// AddMatch for a rule text.
fn void? add_match(Connection* c, String rule_text) @private
{
	Message* call = bus_method(c, "AddMatch")!;
	defer call.release();
	call.body_writer("s")!.append_string(rule_text)!;
	Message* reply = c.call(call)!;
	reply.release();
}

// RemoveMatch for a rule text.
fn void? remove_match(Connection* c, String rule_text) @private
{
	Message* call = bus_method(c, "RemoveMatch")!;
	defer call.release();
	call.body_writer("s")!.append_string(rule_text)!;
	Message* reply = c.call(call)!;
	reply.release();
}

// Records who owns a well-known name now, and asks the bus to report its changes.
fn void? track_sender(Connection* c, String name) @private
{
	if (name[0] == ':' || c.tracks_name(name)) return;
	match::Match changes;
	changes.init(c.allocator);
	changes.with_type(MessageType.SIGNAL)!;
	changes.with_sender(connection::BUS_NAME)!;
	changes.with_interface(connection::BUS_INTERFACE)!;
	changes.with_member(NAME_OWNER_CHANGED)!;
	changes.with_arg(0, name)!;
	add_match(c, changes.rule_text())!;
	changes.free();
	c.set_owner(name, "");
	Message* call = bus_method(c, "GetNameOwner")!;
	defer call.release();
	call.body_writer("s")!.append_string(name)!;
	if (try reply = c.call(call))
	{
		defer reply.release();
		c.set_owner(name, reply.reader()!.read_string()!);
	}
}

// The strings of an `as` argument, copied into `allocator`.
fn String[]? string_array(Reader r, Allocator allocator) @private
{
	Value list = r.read_value(allocator)!;
	String[] out = alloc::new_array(allocator, String, (sz)list.count());
	for (usz i = 0; i < out.len; i++) out[i] = list.at(i)!.as_string()!;
	return out;
}
