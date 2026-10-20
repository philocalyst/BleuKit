<*
 A Wayland client: a `Display` plus the objects every client needs (`wl_display`,
 `wl_registry`) and the registry's list of globals.

 The client is the entry point of the library. It does not connect by itself on
 non-POSIX systems; `Client.connect` and `Client.connect_env` are in `client_posix.c3`,
 and `Client.init` takes a descriptor the caller already has (a socket pair in tests,
 or `WAYLAND_SOCKET`).

 Threading: one thread owns a client. Requests and `bind` may only be called there.
*>
module bleu::wl;
import bleu::error, bleu::rt, bleu::wl::display, bleu::wl::wire, bleu::wl::proto::wayland, std::collections::list;

<*
 A global object the compositor advertised: the name to bind it by, the interface it
 implements, and the highest version the compositor supports. `interface_name` is a
 copy owned by the client, valid until the global is removed.
*>
struct Global
{
	uint name;
	uint version;
	String interface_name;
}

<* Called when the compositor advertises a global. `global` is valid during the call only. *>
alias GlobalAddedFn = fn void(void* context, Global global);

<* Called when the compositor removes a global. Bindings to it stay valid until their server side is gone. *>
alias GlobalRemovedFn = fn void(void* context, uint name);

<* Optional observers of the global list. A null field ignores its event. *>
struct ClientListener
{
	GlobalAddedFn global_added;
	GlobalRemovedFn global_removed;
}

<*
 A connection. Create it in place with `init` (or `connect`) and do not move it: the
 display's proxies point back to it. `root` and `registry` are typed views of the
 `wl_display` and `wl_registry` objects.
*>
struct Client
{
	Allocator allocator;
	display::Display conn;
	wayland::WlDisplay* root;
	wayland::WlRegistry* registry;
	List{Global} globals;
	ClientListener* listener;
	void* listener_context;
	bool sync_done;
}

<*
 Start a client on a connected descriptor. The client owns it from success on; on
 failure the caller still owns it and closes it. The globals arrive with the first
 roundtrip.

 @param allocator : "Allocator for the connection's state"
 @param fd : "A connected Wayland socket"
 @return? error::NO_MEMORY : "Allocation failed"
 @return? error::INVALID_STATE : "The object table could not be set up"
*>
fn void? Client.init(&self, Allocator allocator, rt::Native fd)
{
	self.conn.adopt(allocator, fd, wayland::WL_DISPLAY)!;
	bool ready = false;
	defer if (!ready) self.conn.close();
	self.allocator = allocator;
	self.root = (wayland::WlDisplay*)self.conn.find(display::DISPLAY_ID);
	self.globals.init(allocator, 16);
	self.listener = null;
	self.listener_context = null;
	self.sync_done = false;
	self.registry = self.root.get_registry()!;
	self.registry.set_listener(&REGISTRY_LISTENER, self);
	ready = true;
}

<* Close the connection, free the global list and every proxy. The client must not be used afterwards. *>
fn void Client.close(&self)
{
	self.conn.close();
	foreach (global : self.globals.array_view()) alloc::free(self.allocator, global.interface_name.ptr);
	self.globals.free();
}

<* The descriptor a poller waits on. See `Display.native`. *>
fn rt::Native Client.native(&self) @inline => self.conn.native();

<* Whether a request is queued and not yet written. *>
fn bool Client.wants_write(&self) @inline => self.conn.wants_write();

<* Write queued requests. Returns true when none remain; see `Display.flush`. *>
fn bool? Client.flush(&self) => self.conn.flush();

<* Read and deliver events. Returns how many messages were handled; see `Display.dispatch`. *>
fn usz? Client.dispatch(&self) => self.conn.dispatch();

<* Set the observers of the global list. The listener must outlive the client. *>
fn void Client.set_listener(&self, ClientListener* listener, void* context)
{
	self.listener = listener;
	self.listener_context = context;
}

<* The globals advertised so far, in the order they were added. Valid until the next event is dispatched. *>
fn Global[] Client.globals_view(&self) => self.globals.array_view();

<*
 Ask the compositor to deliver every pending event and wait until it has answered.
 This is how the global list is filled after `init`. Needs a blocking descriptor.

 @return? error::INVALID_STATE : "The descriptor is non-blocking: use a poller and `dispatch`"
 @return? error::DISCONNECTED, error::PROTOCOL, error::BACKEND_FAILURE : "The connection failed"
*>
fn void? Client.roundtrip(&self)
{
	if (self.conn.is_nonblocking())
	{
		return error::raise(error::INVALID_STATE, error::Domain.INTERNAL, 0, "roundtrip needs a blocking descriptor")~;
	}
	self.sync_done = false;
	wayland::WlCallback* callback = self.root.sync()!;
	callback.set_listener(&SYNC_LISTENER, &self.sync_done);
	while (!(self.conn.flush()!))
	{
	}
	while (!self.sync_done) self.conn.dispatch()!;
}

<*
 Bind a global to an object of interface `iface`, at the lower of the two versions. The
 returned proxy converts to the typed view of `iface` (for example `WlOutput*`).

 @param global : "A global from `globals_view`"
 @return? error::INVALID_ARGUMENT : "The global is not an instance of `iface`"
 @return? error::OUT_OF_RANGE, error::INVALID_STATE : "No client id is free, or the display has failed"
*>
fn display::Proxy*? Client.bind(&self, Global global, display::Interface iface)
{
	if (global.interface_name != iface.name)
	{
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"global %d is %s, not %s",
			global.name,
			global.interface_name,
			iface.name
		)~;
	}
	uint version           = min(global.version, iface.version);
	display::Proxy* object = self.conn.new_object(iface, version)!;
	self.registry.bind(global.name, iface.name, version, object)!;
	return object;
}

// Registry listener: keeps the global list and forwards each change to the user's listener.
const wayland::WlRegistryListener REGISTRY_LISTENER = { .global = &on_global, .global_remove = &on_global_remove };

fn void on_global(void* context, wayland::WlRegistry* target, uint name, String interface_name, uint version)
{
	Client* client = (Client*)context;
	Global global  = { .name = name, .version = version, .interface_name = interface_name.copy(client.allocator) };
	client.globals.push(global);
	if (client.listener != null && client.listener.global_added != null)
	{
		client.listener.global_added(client.listener_context, global);
	}
}

fn void on_global_remove(void* context, wayland::WlRegistry* target, uint name)
{
	Client* client = (Client*)context;
	foreach (i, global : client.globals.array_view())
	{
		if (global.name != name) continue;
		alloc::free(client.allocator, global.interface_name.ptr);
		client.globals.remove_at((sz)i);
		break;
	}
	if (client.listener != null && client.listener.global_removed != null)
	{
		client.listener.global_removed(client.listener_context, name);
	}
}

// Sync listener: the callback's context is the client's `sync_done` flag.
const wayland::WlCallbackListener SYNC_LISTENER = { .done = &on_sync_done };

fn void on_sync_done(void* context, wayland::WlCallback* target, uint callback_data)
{
	bool* done = (bool*)context;
	*done = true;
}