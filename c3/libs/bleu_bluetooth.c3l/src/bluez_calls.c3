<*
 Executing requests on BlueZ: each command becomes a method call or a property
 write on the object it names. Commands that BlueZ answers later (Pair,
 Connect, ...) return at once; their reply completes the task.
*>
module bleu::bluetooth::bluez @feat(LINUX);
import std::collections::list, bleu::bluetooth, bleu::dbus::connection, bleu::dbus::message, bleu::dbus::proxy, bleu::dbus::value, bleu::error, bleu::operation;

// BlueZ's names for conditions that a request asks for but which already hold.
const String ALREADY_CONNECTED       = "org.bluez.Error.AlreadyConnected";
const String ALREADY_EXISTS          = "org.bluez.Error.AlreadyExists";
const String NOT_CONNECTED           = "org.bluez.Error.NotConnected";
const String CANCELED                = "org.bluez.Error.Canceled";
const String AUTHENTICATION_CANCELED = "org.bluez.Error.AuthenticationCanceled";
const String DOES_NOT_EXIST          = "org.bluez.Error.DoesNotExist";
const String NOT_AVAILABLE           = "org.bluez.Error.NotAvailable";
const String NOT_READY               = "org.bluez.Error.NotReady";

// What an asynchronous call needs when its reply arrives. Lives in the task's arena.
struct Pending
{
	Task* task; // retained for the call; released when the reply has been applied
	String tolerated; // an error name that means the request already holds: success
}

// The command, run now. Returns an error when the request is refused at once.
fn void? perform(Bluez* self, Request* r) @private
{
	switch (r.kind)
	{
		case bluetooth::Command.SET_POWERED: return write_adapter(self, r, "Powered", value::boolean(r.flag));
		case bluetooth::Command.SET_DISCOVERABLE:
			if (r.flag) write_adapter(self, r, "DiscoverableTimeout", value::u32(r.number))!;
			return write_adapter(self, r, "Discoverable", value::boolean(r.flag));
		case bluetooth::Command.SET_PAIRABLE: return write_adapter(self, r, "Pairable", value::boolean(r.flag));
		case bluetooth::Command.START_DISCOVERY: return start_discovery(self, r);
		case bluetooth::Command.STOP_DISCOVERY: return adapter_method(self, r, "StopDiscovery");
		case bluetooth::Command.PAIR: return device_method(self, r, "Pair", "", ALREADY_EXISTS);
		case bluetooth::Command.CANCEL_PAIRING: return device_method(self, r, "CancelPairing", "", "");
		case bluetooth::Command.CONNECT: return device_method(self, r, "Connect", "", ALREADY_CONNECTED);
		case bluetooth::Command.DISCONNECT: return device_method(self, r, "Disconnect", "", NOT_CONNECTED);
		case bluetooth::Command.CONNECT_PROFILE: return device_method(self, r, "ConnectProfile", bluetooth::profile_uuid(r.profile), ALREADY_CONNECTED);
		case bluetooth::Command.DISCONNECT_PROFILE: return device_method(self, r, "DisconnectProfile", bluetooth::profile_uuid(r.profile), NOT_CONNECTED);
		case bluetooth::Command.SET_TRUSTED: return write_device(self, r, "Trusted", value::boolean(r.flag));
		case bluetooth::Command.SET_BLOCKED: return write_device(self, r, "Blocked", value::boolean(r.flag));
		case bluetooth::Command.RENAME: return write_device(self, r, "Alias", value::str(r.op.allocator(), r.text)!);
		case bluetooth::Command.REMOVE: return remove_device(self, r);
		case bluetooth::Command.REPLY_PAIRING: return error::UNSUPPORTED~;
		case bluetooth::Command.REFRESH: return;
	}
}

// Commands whose completion is the reply of a call, rather than the end of `perform`.
fn bool is_asynchronous(Command kind) @inline
{
	switch (kind)
	{
		case bluetooth::Command.PAIR:
		case bluetooth::Command.CONNECT:
		case bluetooth::Command.DISCONNECT:
		case bluetooth::Command.CONNECT_PROFILE:
		case bluetooth::Command.DISCONNECT_PROFILE: return true;
		default: return false;
	}
}

<*
 Run one request from the mailbox: complete it now, or leave it to its reply.
 Consumes the request's reference to the task.
*>
fn void execute(Bluez* self, Request* r)
{
	Task* task = r.op;
	defer task.release();
	task.start();
	// The messages and values built for the request live in the temporary allocator until the bus has them.
	@pool()
	{
		if (catch err = perform(self, r))
		{
			task.fail(err);
		}
		else if (!is_asynchronous(r.kind))
		{
			task.succeed(bluetooth::Done.DONE);
		}
	};
}

// The proxy of `interface_name` on `path` at BlueZ.
fn Proxy? object_proxy(Bluez* self, String path, String interface_name) @private
{
	return proxy::for_object(&self.bus, BLUEZ_NAME, path, interface_name);
}

// The object path of the adapter a request names: the one with that address, or the first when none is named.
fn String? adapter_path(Bluez* self, Request* r) @private
{
	return find_object(self, ADAPTER_IFACE, r.adapter, r.op.allocator())!;
}

// The object path of the device a request names.
fn String? device_path(Bluez* self, Request* r) @private
{
	return find_object(self, DEVICE_IFACE, r.device, r.op.allocator())!;
}

<*
 The object path of the first object whose `interface_name` has `Address` equal
 to `address`, or of the first such object when `address` is empty. The path
 is copied into `allocator`.

 @return? NOT_FOUND : "No object has that address"
*>
fn String? find_object(Bluez* self, String interface_name, String address, Allocator allocator) @private
{
	@pool()
	{
		Proxy root = proxy::for_object(&self.bus, BLUEZ_NAME, BLUEZ_ROOT, proxy::OBJECT_MANAGER_INTERFACE)!;
		Value tree = root.get_managed_objects(tmem)!;
		foreach (object : tree.items)
		{
			if (try props = interface_props(object, interface_name))
			{
				if (address.len == 0 || text_prop(props, "Address", tmem) == address)
				{
					return bluetooth::copy_text(object.items[0].text, allocator);
				}
			}
		}
		return NOT_FOUND~;
	};
}

// Sets one property of the adapter a request names.
fn void? write_adapter(Bluez* self, Request* r, String name, Value v) @private
{
	String path   = adapter_path(self, r)!;
	Proxy adapter = object_proxy(self, path, ADAPTER_IFACE)!;
	adapter.set_property(name, v)!;
}

// Sets one property of the device a request names.
fn void? write_device(Bluez* self, Request* r, String name, Value v) @private
{
	String path  = device_path(self, r)!;
	Proxy device = object_proxy(self, path, DEVICE_IFACE)!;
	device.set_property(name, v)!;
}

// Calls a method without arguments on the adapter a request names.
fn void? adapter_method(Bluez* self, Request* r, String member) @private
{
	String path   = adapter_path(self, r)!;
	Proxy adapter = object_proxy(self, path, ADAPTER_IFACE)!;
	Message* call = adapter.new_call(tmem, member)!;
	call_sync(self, call)!;
}

fn void? start_discovery(Bluez* self, Request* r) @private
{
	String path     = adapter_path(self, r)!;
	Proxy adapter   = object_proxy(self, path, ADAPTER_IFACE)!;
	Message* filter = adapter.new_call(tmem, "SetDiscoveryFilter")!;
	filter.body_writer("a{sv}")!.append_value(discovery_filter(r)!)!;
	call_sync(self, filter)!;
	Message* start = adapter.new_call(tmem, "StartDiscovery")!;
	call_sync(self, start)!;
}

// The `a{sv}` of a discovery filter, as BlueZ's SetDiscoveryFilter reads it.
fn Value? discovery_filter(Request* r) @private
{
	Allocator a = tmem;
	List{Value} entries;
	entries.init(a);
	entries.push(entry(a, "Transport", value::str(a, transport_name(r.filter.transport))!)!);
	entries.push(entry(a, "DuplicateData", value::boolean(r.filter.duplicates))!);
	if (r.filter.rssi_floor.has_value)
	{
		entries.push(entry(a, "RSSI", value::variant(a, value::i16((short)r.filter.rssi_floor.value)))!);
	}
	if (r.filter.pattern.len > 0)
	{
		entries.push(entry(a, "Pattern", value::variant(a, value::str(a, r.filter.pattern)!))!);
	}
	return value::array(a, "{sv}", entries.array_view())!;
}

fn Value? entry(Allocator a, String key, Value v) @private
{
	return value::dict_entry(a, value::str(a, key)!, value::variant(a, v));
}

// BlueZ's spelling of the transport filter values.
fn String transport_name(Transport transport) @private
{
	switch (transport)
	{
		case bluetooth::Transport.AUTO: return "auto";
		case bluetooth::Transport.LE: return "le";
		case bluetooth::Transport.BR_EDR: return "bredr";
	}
}

// Calls a method on the device a request names. `argument` is a string argument ("" for none).
fn void? device_method(Bluez* self, Request* r, String member, String argument, String tolerated) @private
{
	String path   = device_path(self, r)!;
	Proxy device  = object_proxy(self, path, DEVICE_IFACE)!;
	Message* call = device.new_call(tmem, member)!;
	if (argument.len > 0) call.body_writer("s")!.append_string(argument)!;
	// Synchronous methods finish here; the others complete their task when the reply arrives.
	if (!is_asynchronous(r.kind))
	{
		call_sync(self, call)!;
		return;
	}
	call_async(self, r.op, call, tolerated)!;
}

// Removes a device from its adapter. BlueZ's RemoveDevice is a method of the adapter, so the adapter is read first.
fn void? remove_device(Bluez* self, Request* r) @private
{
	String path           = device_path(self, r)!;
	Proxy device          = object_proxy(self, path, DEVICE_IFACE)!;
	Value adapter_value   = device.get_property("Adapter", r.op.allocator())!;
	String adapter_object = adapter_value.as_object_path()!;
	Proxy adapter         = object_proxy(self, adapter_object, ADAPTER_IFACE)!;
	Message* call         = adapter.new_call(tmem, "RemoveDevice")!;
	call.body_writer("o")!.append_object_path(path)!;
	call_sync(self, call)!;
}

// Sends a call and waits for its reply on the worker. The message is released here.
fn void? call_sync(Bluez* self, Message* call) @private
{
	defer call.release();
	Message* reply = self.bus.call(call)!;
	reply.release();
}

// Sends a call whose reply completes `task`. Takes its own reference to the task.
fn void? call_async(Bluez* self, Task* task, Message* call, String tolerated) @private
{
	defer call.release();
	Pending* pending = alloc::new(task.allocator(), Pending, { .task = task.retain(), .tolerated = tolerated });
	if (catch err = self.bus.call_async(call, &on_reply, pending))
	{
		task.release();
		return err~;
	}
}

// A reply to an asynchronous call: success, the tolerated "already holds" case, or the mapped failure.
fn void on_reply(void* context, Message* reply, error::Status status)
{
	Pending* pending = (Pending*)context;
	Task* task       = pending.task;
	if (reply != null || tolerated_error(pending.tolerated))
	{
		task.succeed(bluetooth::Done.DONE);
	}
	else
	{
		task.fail(failure_of(status));
	}
	task.release();
}

// True when the last failure on this thread is the BlueZ error `name`.
fn bool tolerated_error(String name) @private
{
	if (name.len == 0) return false;
	Detail* last = error::last();
	return last.domain == error::Domain.DBUS && error_name(last.message()) == name;
}

// The BlueZ error name at the front of a D-Bus error text ("name: message").
fn String error_name(String text) @private
{
	sz colon = text.index_of_char(':') ?? text.len;
	return text[0:colon];
}

// The excuse for a failed reply: BlueZ's own names where the meaning is clear, otherwise the status.
fn fault failure_of(error::Status status) @private
{
	Detail* last = error::last();
	if (status != error::Status.DISCONNECTED && last.domain == error::Domain.DBUS)
	{
		String name = error_name(last.message());
		if (name == CANCELED || name == AUTHENTICATION_CANCELED) return error::CANCELLED;
		if (name == DOES_NOT_EXIST) return NOT_FOUND;
		if (name == NOT_AVAILABLE || name == NOT_READY) return error::UNAVAILABLE;
	}
	if (status == error::Status.OK) return error::BACKEND_FAILURE;
	return error::fault_of(status);
}