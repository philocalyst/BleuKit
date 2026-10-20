<*
 Owning a well-known bus name, with the queueing rules of the bus.

 `Connection.own_name` asks the bus for a name and keeps the caller informed:
 `on_acquired` runs when this connection holds the name, and `on_lost` runs when
 it loses it. The bus decides, by the flags the caller gives, whether a request
 that cannot be granted now is refused (`DO_NOT_QUEUE`), queued until the name
 is free, or allowed to take the name from its owner (`REPLACE_EXISTING`, which
 the owner has to allow with `ALLOW_REPLACEMENT`).

 The handlers run from `process()`, on the connection's thread.

 Sources: D-Bus specification, "Message Bus Specification": RequestName (flags,
 reply codes), ReleaseName, and the NameAcquired and NameLost signals.
*>
module bleu::dbus::ownership;
import bleu::error, bleu::dbus::bus, bleu::dbus::connection, bleu::dbus::match, bleu::dbus::message, bleu::dbus::names;

<*
 Called when this connection gets a name, or loses one. `name` is valid during the call.
*>
alias NameHandler = fn void(void* context, String name);

<*
 A well-known name this connection owns or waits for. `release` gives it up
 and frees this value; it is not freed with the connection.
*>
struct OwnedName
{
	Connection* connection;
	DString name;
	bool held;
	SubscriptionId acquired;
	SubscriptionId lost;
	NameHandler on_acquired;
	NameHandler on_lost;
	void* context;
}

<*
 Ask the bus for `name`, with `flags` (any of `bus::NAME_ALLOW_REPLACEMENT`,
 `NAME_REPLACE_EXISTING`, `NAME_DO_NOT_QUEUE`). If the name is granted at once,
 `on_acquired` runs before this returns. If the bus queues the request,
 `on_acquired` runs later, when the name is handed over, and nothing is held
 meanwhile. `on_lost` may be null.

 @param on_acquired : "Run when this connection holds the name"
 @param on_lost : "Run when this connection loses the name, or null"
 @param context : "Passed to both handlers"
 @return "The ownership; release it to give the name up"
 @return? error::INVALID_ARGUMENT : "Not a well-known bus name, or no `on_acquired` handler"
 @return? error::BUSY : "The name is owned elsewhere and the request asked not to queue"
 @return? error::DISCONNECTED : "The bus did not answer the request"
*>
fn OwnedName*? Connection.own_name(
	&self,
	String name,
	uint flags,
	NameHandler on_acquired,
	NameHandler on_lost,
	void* context
)
{
	if (!names::is_bus_name(name) || name[0] == ':' || !on_acquired) return error::INVALID_ARGUMENT~;
	OwnedName* o = alloc::new(self.allocator, OwnedName);
	*o = { .connection = self, .on_acquired = on_acquired, .on_lost = on_lost, .context = context };
	o.name.init(self.allocator);
	o.name.append_string(name);
	if (catch err = o.subscribe_signals())
	{
		free_owned(o);
		return err~;
	}
	NameReply reply = self.request_name(name, flags) ?? UNKNOWN_REPLY;
	switch (reply)
	{
		case PRIMARY_OWNER:
		case ALREADY_OWNER:
			o.held = true;
			on_acquired(context, name);
		case IN_QUEUE:
			return o; // NameAcquired arrives when the bus hands the name over
		case EXISTS:
			o.unsubscribe_signals();
			free_owned(o);
			return error::raise(
				error::BUSY,
				error::Domain.DBUS,
				0,
				"the name %s is owned and the request does not queue",
				name
			)~;
		case UNKNOWN_REPLY:
			o.unsubscribe_signals();
			free_owned(o);
			return error::raise(
				error::BACKEND_FAILURE,
				error::Domain.DBUS,
				0,
				"the bus gave no answer to RequestName for %s",
				name
			)~;
	}
	return o;
}

<*
 Give the name up, if it is held or queued, stop the handlers, and free this value.

 @return? error::DISCONNECTED : "The bus did not answer ReleaseName; the name is gone with the connection"
*>
fn void? OwnedName.release(&self)
{
	Connection* c = self.connection;
	defer free_owned(self);
	self.unsubscribe_signals();
	// A queued request is withdrawn too, so the bus does not grant the name later.
	// A closed connection has no names left to give back.
	if (c.is_open) c.release_name(self.name.str_view())!;
}

// Subscribes to NameAcquired and NameLost for the name, sent to this connection by the bus.
fn void? OwnedName.subscribe_signals(&self)
{
	Connection* c = self.connection;
	self.acquired = c.subscribe(bus_name_rule(c, "NameAcquired", self.name.str_view())!, &on_name_acquired, self)!;
	self.lost = c.subscribe(bus_name_rule(c, "NameLost", self.name.str_view())!, &on_name_lost, self)!;
}

// Stops the NameAcquired and NameLost subscriptions. Their handlers do not run after this.
fn void OwnedName.unsubscribe_signals(&self)
{
	Connection* c = self.connection;
	if (catch c.unsubscribe(self.acquired))
	{
	}
	if (catch c.unsubscribe(self.lost))
	{
	}
}

// A match rule for one of the bus's signals about `name`: sent by the bus, with the name as its first argument.
fn match::Match? bus_name_rule(Connection* c, String member, String name) @private
{
	match::Match rule;
	rule.init(c.allocator);
	if (catch err = fill_rule(&rule, member, name))
	{
		rule.free();
		return err~;
	}
	return rule;
}

// Writes the constraints of a bus_name_rule into `rule`.
fn void? fill_rule(match::Match* rule, String member, String name) @private
{
	rule.with_type(message::MessageType.SIGNAL)!;
	rule.with_sender(connection::BUS_NAME)!;
	rule.with_interface(connection::BUS_INTERFACE)!;
	rule.with_member(member)!;
	rule.with_arg(0, name)!;
}

// The bus granted the name (to this connection, or to it from the queue).
fn void on_name_acquired(void* context, Message* signal) @private
{
	OwnedName* o = (OwnedName*)context;
	if (o.held) return;
	o.held = true;
	o.on_acquired(o.context, o.name.str_view());
}

// The bus took the name from this connection.
fn void on_name_lost(void* context, Message* signal) @private
{
	OwnedName* o = (OwnedName*)context;
	if (!o.held) return;
	o.held = false;
	if (o.on_lost) o.on_lost(o.context, o.name.str_view());
}

// Frees an ownership and its name.
fn void free_owned(OwnedName* o) @private
{
	Connection* c = o.connection;
	o.name.free();
	alloc::free(c.allocator, o);
}