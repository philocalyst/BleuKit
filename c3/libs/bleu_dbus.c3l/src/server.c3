<*
 Server-side object export: an `ObjectServer` serves exported objects on a
 `Connection` (or on any other message sink) and implements the standard
 interfaces for them.

 Everything runs on the connection's thread. Handlers run inside
 `Connection.process()`, so they may emit signals, but they must not call
 `process()` or `close()`. A handler that cannot answer at once calls
 `Call.defer_reply`, returns, and answers later with `ObjectServer.reply` or
 `ObjectServer.reply_error` (on the same thread).

 Routing, for an incoming METHOD_CALL:

 * Peer, Introspectable.Introspect and the object's own standard interfaces
 (Properties, ObjectManager) are answered by the server.
 * The object is the exported object at the path, or else the fallback with
 the longest prefix that covers the path.
 * The method is found in the interface the call names (or in any interface,
 when the call names none). The body's signature must equal the declared
 in-signature, or the call gets `org.freedesktop.DBus.Error.InvalidArgs`.
 * Anything else gets `UnknownObject`, `UnknownInterface` or `UnknownMethod`.

 The server keeps references to the interface tables, not copies. Free it
 before the connection it is attached to.

 Sources: D-Bus specification, "Standard Interfaces" (Introspectable, Properties,
 Peer, ObjectManager), "Message Bus Specification" for the error names, and
 "Introspection Data Format" (the introspect DTD).
*>
module bleu::dbus::server;
import bleu::error, bleu::dbus::connection, bleu::dbus::message, bleu::dbus::names;
import std::collections::list;

<* Interface of the peer-to-peer methods, which every object answers. *>
const INTERFACE_PEER = "org.freedesktop.DBus.Peer";

<* Interface of the introspection method. *>
const INTERFACE_INTROSPECTABLE = "org.freedesktop.DBus.Introspectable";

<* Interface of the property accessors and PropertiesChanged. *>
const INTERFACE_PROPERTIES = "org.freedesktop.DBus.Properties";

<* Interface of GetManagedObjects, InterfacesAdded and InterfacesRemoved. *>
const INTERFACE_OBJECT_MANAGER = "org.freedesktop.DBus.ObjectManager";

<* The D-Bus errors the server answers with itself. *>
const ERROR_FAILED             = "org.freedesktop.DBus.Error.Failed";
const ERROR_INVALID_ARGS       = "org.freedesktop.DBus.Error.InvalidArgs";
const ERROR_UNKNOWN_METHOD     = "org.freedesktop.DBus.Error.UnknownMethod";
const ERROR_UNKNOWN_OBJECT     = "org.freedesktop.DBus.Error.UnknownObject";
const ERROR_UNKNOWN_INTERFACE  = "org.freedesktop.DBus.Error.UnknownInterface";
const ERROR_UNKNOWN_PROPERTY   = "org.freedesktop.DBus.Error.UnknownProperty";
const ERROR_PROPERTY_READ_ONLY = "org.freedesktop.DBus.Error.PropertyReadOnly";

<*
 Names a deferred reply: returned by `Call.defer_reply`, used once by
 `ObjectServer.reply` or `ObjectServer.reply_error`. Zero is never a token.
*>
typedef ReplyToken = uint;

<*
 Transmits a message the server built. The message is valid only during the
 call. `attach` sends through the connection; `use_sink` installs another sink.
*>
alias MessageSink = fn void?(void* context, Message* message);

// An exported object: its path, the interfaces it implements, and whether it is an ObjectManager root.
struct Export
{
	DString path;
	Interface[] interfaces;
	bool manager;
}

// A fallback: the interfaces served under a path prefix.
struct Fallback
{
	DString prefix;
	Interface[] interfaces;
}

// A reply that was deferred: where it goes, and what shape it must have.
struct Deferred
{
	ReplyToken token;
	DString destination;
	uint serial;
	DString out_signature;
	bool expects_reply;
}

// The object a path resolves to: its interfaces, and whether it is an ObjectManager root.
struct Target
{
	bool found;
	Interface[] interfaces;
	bool manager;
}

<*
 Serves exported objects. Initialise with `init`, release with `free`.
*>
struct ObjectServer
{
	Allocator allocator;
	MessageSink sink;
	void* sink_context;
	Connection* connection;
	List{Export*} exports;
	List{Fallback*} fallbacks;
	List{Deferred*} deferred;
	uint next_token;
}

<*
 Prepare a server with no objects. It does not send or receive anything until
 `attach` or `use_sink`.

 @param [&inout] allocator : "Allocator for the exports and for the messages the server builds"
*>
fn void ObjectServer.init(&self, Allocator allocator)
{
	*self = { .allocator = allocator, .next_token = 1 };
	self.exports.init(allocator);
	self.fallbacks.init(allocator);
	self.deferred.init(allocator);
}

<* Stop serving: detach from the connection, and release every export and deferred reply. *>
fn void ObjectServer.free(&self)
{
	if (self.connection != null) self.connection.set_incoming_handler(null, null);
	self.connection = null;
	foreach (e : self.exports)
	{
		e.path.free();
		alloc::free(self.allocator, e);
	}
	self.exports.free();
	foreach (f : self.fallbacks)
	{
		f.prefix.free();
		alloc::free(self.allocator, f);
	}
	self.fallbacks.free();
	foreach (d : self.deferred) free_deferred(self, d);
	self.deferred.free();
}

<*
 Serve the objects through `connection`: its incoming method calls are answered
 here, from `process()`, and replies and signals are sent through it. The
 connection must be on the thread that calls this.
*>
fn void ObjectServer.attach(&self, Connection* connection)
{
	self.sink = &send_on_connection;
	self.sink_context = connection;
	self.connection = connection;
	connection.set_incoming_handler(&route_call, self);
}

<*
 Send replies and signals through `sink` instead of a connection. For a transport
 other than `Connection`, and for tests. Incoming calls then come through `handle`.

 @param context : "Passed to the sink"
*>
fn void ObjectServer.use_sink(&self, MessageSink sink, void* context)
{
	self.sink = sink;
	self.sink_context = context;
}

// Sends a message on a connection. A failure means the connection has closed.
fn void? send_on_connection(void* context, Message* message) @private
{
	Connection* c = (Connection*)context;
	if (catch err = c.send(message)) return err~;
}

// The connection's incoming-call hook: every call is the server's to answer.
fn bool route_call(void* context, Message* call) @private
{
	ObjectServer* server = (ObjectServer*)context;
	server.handle(call);
	return true;
}

<*
 Answer one incoming METHOD_CALL. Every call gets an answer, unless the caller
 said NO_REPLY_EXPECTED. A call that the server cannot route, or whose handler
 fails, is answered with the error that says why.

 Transports other than `Connection` call this for each call they receive.

 @param call : "The METHOD_CALL; valid during the call"
*>
fn void ObjectServer.handle(&self, Message* call)
{
	@pool()
	{
		Call c = {
			.server = self,
			.message = call,
			.path = call.path,
			.interface_name = call.interface_name,
			.member = call.member,
			.sender = call.sender,
			.serial = call.serial,
			.expects_reply = (call.flags & message::FLAG_NO_REPLY_EXPECTED) == 0,
		};
		if (catch err = self.dispatch(&c)) fail_call(&c, err);
	};
}

// Routes one call to the standard interface, object or method it names. Routing
// failures are answered here; a handler's failure is returned for `fail_call`.
fn void? ObjectServer.dispatch(&self, Call* c)
{
	if (c.interface_name == INTERFACE_PEER) return peer_call(c);
	if (c.interface_name == INTERFACE_INTROSPECTABLE && c.member == "Introspect") return introspect_call(c);
	Target target = self.find_target(c.path);
	if (!target.found) return c.reply_error(ERROR_UNKNOWN_OBJECT, string::tformat("no object at %s", c.path));
	if (c.interface_name == INTERFACE_PROPERTIES) return properties_call(c, &target);
	if (c.interface_name == INTERFACE_OBJECT_MANAGER)
	{
		if (!target.manager) return c.reply_error(
			ERROR_UNKNOWN_INTERFACE,
			string::tformat("no interface %s at %s", c.interface_name, c.path)
		);
		return managed_objects_call(c);
	}
	return self.user_call(c, &target);
}

// Routes a call to a method of the object's own interfaces, and runs its handler.
fn void? ObjectServer.user_call(&self, Call* c, Target* target)
{
	Method* method = null;
	if (c.interface_name.len == 0)
	{
		for (sz k = 0; k < target.interfaces.len && method == null; k++)
		{
			method = find_method(&target.interfaces[k], c.member);
		}
	}
	else
	{
		Interface* i = find_interface(target.interfaces, c.interface_name);
		if (i == null) return c.reply_error(
			ERROR_UNKNOWN_INTERFACE,
			string::tformat("no interface %s at %s", c.interface_name, c.path)
		);
		method = find_method(i, c.member);
	}
	if (method == null) return c.reply_error(ERROR_UNKNOWN_METHOD, string::tformat("no method %s here", c.member));
	String received = incoming_signature(c.message);
	if (received != method.in_signature)
	{
		return c.reply_error(
			ERROR_INVALID_ARGS,
			string::tformat("%s takes '%s', not '%s'", c.member, method.in_signature, received)
		);
	}
	c.out_signature = method.out_signature;
	method.handler(method.context, c)!;
	if (!c.answered) return c.reply({ });
}

// Answers a call whose handler failed with `failure`, unless the handler answered it already.
fn void fail_call(Call* c, fault failure) @private
{
	if (c.deferred != (ReplyToken)0)
	{
		// The handler deferred the call and then failed: the failure is the deferred call's answer.
		// If the handler answered it already, the token is used up and this is refused, which is right.
		if (catch c.server.reply_error(c.deferred, error_name_for(failure), detail_text(failure)))
		{
		}
		return;
	}
	if (c.answered) return;
	c.answered = true;
	if (!c.expects_reply) return;
	// If the connection is gone the send fails; the next process() reports that, so nothing is lost here.
	if (catch send_error_reply(c.server, c.sender, c.serial, error_name_for(failure), detail_text(failure)))
	{
	}
}

// The signature of a call's body: the written one, for a message built in memory; else the received one.
fn String incoming_signature(Message* m) @private => m.has_writer ? m.writer.signature : m.signature;

// The export at exactly `path`, or null.
fn Export* ObjectServer.export_at(&self, String path)
{
	foreach (e : self.exports)
	{
		if (e.path.str_view() == path) return e;
	}
	return null;
}

// What `path` resolves to: the exact export, else the longest matching fallback, else nothing.
fn Target ObjectServer.find_target(&self, String path)
{
	Export* e = self.export_at(path);
	if (e != null) return { .found = true, .interfaces = e.interfaces, .manager = e.manager };
	Fallback* best = null;
	foreach (f : self.fallbacks)
	{
		if (!path.starts_with(f.prefix.str_view())) continue;
		if (best == null || f.prefix.len() > best.prefix.len()) best = f;
	}
	if (best == null) return { };
	return { .found = true, .interfaces = best.interfaces };
}

<*
 Make the object at `path` answer for `interfaces`. The tables are referenced,
 not copied, so they must outlive the export. When an ObjectManager root is above
 `path`, InterfacesAdded is sent for it. The object stays exported if that send fails.

 @param [in] interfaces : "The interfaces the object implements"
 @return? error::INVALID_ARGUMENT : "The path or an interface description is not valid"
 @return? error::INVALID_STATE : "An object is already exported there, or two interfaces share a name"
 @return? error::DISCONNECTED : "InterfacesAdded could not be sent"
*>
fn void? ObjectServer.export(&self, String path, Interface[] interfaces)
{
	if (!names::is_object_path(path))
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "object path '%s' is not valid", path)~;
	}
	if (self.export_at(path) != null)
	{
		return error::raise(
			error::INVALID_STATE,
			error::Domain.INTERNAL,
			0,
			"an object is already exported at %s",
			path
		)~;
	}
	for (sz k = 0; k < interfaces.len; k++)
	{
		validate_interface(&interfaces[k])!;
		for (sz j = 0; j < k; j++)
		{
			if (interfaces[j].name == interfaces[k].name)
			{
				return error::raise(
					error::INVALID_STATE,
					error::Domain.INTERNAL,
					0,
					"interface %s is listed twice",
					interfaces[k].name
				)~;
			}
		}
	}
	Export* e = alloc::new(self.allocator, Export);
	e.path.init(self.allocator);
	e.path.append_string(path);
	e.interfaces = interfaces;
	self.exports.push(e);
	if (interfaces.len > 0) return self.announce_added(e);
}

<*
 Remove the object at `path`. When an ObjectManager root is above it,
 InterfacesRemoved is sent for it.

 @return? NOT_FOUND : "No object is exported at `path`"
*>
fn void? ObjectServer.unexport(&self, String path)
{
	sz at = -1;
	for (sz k = 0; k < (sz)self.exports.len(); k++)
	{
		if (self.exports.get(k).path.str_view() == path) at = k;
	}
	if (at < 0) return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no object is exported at %s", path)~;
	Export* e = self.exports.get(at);
	self.exports.remove_at(at);
	defer free_export(self, e);
	return self.announce_removed(e);
}

<*
 Make `path` an ObjectManager root: it answers GetManagedObjects for the objects
 below it, and InterfacesAdded and InterfacesRemoved are sent for them. If
 nothing is exported at `path`, an object with no interfaces is exported there.
*>
fn void? ObjectServer.make_object_manager(&self, String path)
{
	Export* e = self.export_at(path);
	if (e == null)
	{
		self.export(path, { })!;
		e = self.export_at(path);
	}
	e.manager = true;
}

<*
 Serve every path under `prefix` with `interfaces`. `prefix` is "/" or an object
 path followed by "/", such as "/org/bleu/items/". An exact export takes
 precedence, and the longest prefix wins. A handler sees the requested path in
 `call.path`, so one table can serve many objects. Fallbacks are not listed by
 Introspect or GetManagedObjects, since their members are not known.

 @param [in] interfaces : "The interfaces every object under the prefix implements"
 @return? error::INVALID_ARGUMENT : "The prefix or an interface description is not valid"
 @return? error::INVALID_STATE : "The prefix is already registered"
*>
fn void? ObjectServer.register_fallback(&self, String prefix, Interface[] interfaces)
{
	if (!is_prefix(prefix))
	{
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"fallback prefix '%s' is not valid",
			prefix
		)~;
	}
	foreach (f : self.fallbacks)
	{
		if (f.prefix.str_view() == prefix)
		{
			return error::raise(
				error::INVALID_STATE,
				error::Domain.INTERNAL,
				0,
				"prefix %s is already registered",
				prefix
			)~;
		}
	}
	for (sz k = 0; k < interfaces.len; k++) validate_interface(&interfaces[k])!;
	Fallback* f = alloc::new(self.allocator, Fallback);
	f.prefix.init(self.allocator);
	f.prefix.append_string(prefix);
	f.interfaces = interfaces;
	self.fallbacks.push(f);
}

// True for "/" and for an object path followed by "/".
fn bool is_prefix(String prefix) @private
{
	if (prefix == "/") return true;
	if (prefix.len < 2 || prefix[prefix.len - 1] != '/') return false;
	return names::is_object_path(prefix[0:prefix.len - 1]);
}

// True when `path` lies strictly below `root` in the object tree.
fn bool is_below(String path, String root) @private
{
	if (root == "/") return path.len > 1 && path[0] == '/';
	return path.len > root.len && path.starts_with(root) && path[root.len] == '/';
}

// Releases an export and its path.
fn void free_export(ObjectServer* server, Export* e) @private
{
	e.path.free();
	alloc::free(server.allocator, e);
}

// Releases a deferred reply that is no longer needed.
fn void free_deferred(ObjectServer* server, Deferred* d) @private
{
	d.destination.free();
	d.out_signature.free();
	alloc::free(server.allocator, d);
}