<*
 The StatusNotifier backend: the tray of the session bus.

 The worker owns one session-bus connection and an object server on it. It serves the
 StatusNotifierWatcher when no other process does, registers as a host, and keeps one record
 per registered item: its properties, its menu, and the signals and owner changes that keep
 both current. Our own icon (`publish_own`) is exported on the same connection.

 One pass of `run` is: wait for the bus, `process()` it, run the mailbox, apply the queued work
 (registrations, signals, owner changes), publish when something changed. Handlers only queue
 work; they never make bus calls, so nothing re-enters. A bus call made from the worker waits
 at most `CALL_TIMEOUT`.

 Sources: docs/research/media_notify_tray.md part (C) section 2.1; KDE
 org.kde.StatusNotifierWatcher.xml and org.kde.StatusNotifierItem.xml; libdbusmenu
 com.canonical.dbusmenu.xml.
*>
module bleu::tray::sni @feat(LINUX);
import std::collections::list, std::os::posix, std::time, bleu::availability, bleu::dbus::bus, bleu::dbus::connection, bleu::dbus::message, bleu::dbus::ownership, bleu::dbus::server, bleu::dbus::value, bleu::dbus::marshal, bleu::error, bleu::observe, bleu::rt, bleu::rt::poller, bleu::rt::worker, bleu::service, bleu::tray, bleu::tray::convert;

// Names, paths and interfaces of the protocol (KDE copies of the freedesktop specification).
const String WATCHER_NAME        = "org.kde.StatusNotifierWatcher";
const String WATCHER_PATH        = "/StatusNotifierWatcher";
const String WATCHER_INTERFACE   = "org.kde.StatusNotifierWatcher";
const String HOST_NAME_PREFIX    = "org.kde.StatusNotifierHost-";
const String ITEM_INTERFACE      = "org.kde.StatusNotifierItem";
const String ITEM_INTERFACE_FDO  = "org.freedesktop.StatusNotifierItem";
const String ITEM_NAME_PREFIX    = "org.kde.StatusNotifierItem-";
const String ITEM_PATH           = "/StatusNotifierItem";
const String OWN_MENU_PATH       = "/MenuBar";
const String MENU_INTERFACE      = "com.canonical.dbusmenu";
const String NO_MENU_PATH        = "/NO_DBUSMENU";
const String PROPERTIES_IFACE    = "org.freedesktop.DBus.Properties";
const String REGISTERED_SIGNAL   = "StatusNotifierItemRegistered";
const String UNREGISTERED_SIGNAL = "StatusNotifierItemUnregistered";
const String HOST_REGISTERED_SIGNAL   = "StatusNotifierHostRegistered";
const String HOST_UNREGISTERED_SIGNAL = "StatusNotifierHostUnregistered";

// How long one bus call may wait for its reply, in microseconds.
const Duration CALL_TIMEOUT = (Duration)1_000_000;
// How long the worker sleeps when nothing happens, in microseconds, before it looks at the bus again.
const Duration RETRY_INTERVAL = (Duration)2_000_000;
// Poller tag of the bus connection; the worker's wake-up is untagged.
const usz CONNECTION_TAG = 1;
// Most queued work items. Beyond it the worker drops them and reads everything again.
const usz PENDING_LIMIT = 256;
// Deepest menu nesting accepted from an application.
const usz MAX_MENU_DEPTH = 32;
// Commands taken from the mailbox per call.
const usz BATCH = 8;
// The number of `Prop` values; each property has its own arena (see `Prop`).
const usz PROP_COUNT = 14;

<*
 Which property of an item a piece of work concerns. Each has its own arena, so a signal that
 changes one property frees and rebuilds only that property's memory.
*>
enum Prop : char
{
	ID,
	CATEGORY,
	TITLE,
	STATUS,
	ICON_NAME,
	ICON_PIXMAP,
	ATTENTION_NAME,
	ATTENTION_PIXMAP,
	OVERLAY_NAME,
	OVERLAY_PIXMAP,
	TOOLTIP,
	THEME_PATH,
	MENU_PATH,
	ITEM_IS_MENU,
}

<*
 One registered item, on the heap. Its arenas own the memory of `item`. `signal_sub` and
 `owner_sub` are removed before the record is freed, so no handler sees a freed record.
*>
struct ItemRecord
{
	SniBackend* backend;
	uint key;
	DynamicArenaAllocator identity; // id, bus name, object path, interface: fixed for the item's life
	DynamicArenaAllocator[PROP_COUNT] arenas;
	DynamicArenaAllocator menu_arena;
	String interface_name;
	tray::Item item;
	MenuNode menu;
	SubscriptionId signal_sub;
	SubscriptionId owner_sub;
	bool subscribed;
}

<* The backend state, on the heap. `destroy` frees it; everything it references is freed by its owner. *>
struct SniBackend
{
	Allocator allocator;
	bool publish_own;
	tray::OwnItem own;
	String own_bus; // our item's well-known name
	String own_item_id; // our item as the watcher knows it: own_bus + "/StatusNotifierItem"
	String host_bus; // our host's well-known name
	Connection connection;
	bool connection_up;
	ObjectServer server;
	OwnedName* host_name;
	OwnedName* own_item_name;
	OwnedName* watcher_name;
	SubscriptionId watcher_owner_sub;
	bool watcher_watch_set;
	SubscriptionId[2] registry_subs;
	bool registry_subs_set;
	bool watcher_present;
	bool watcher_served;
	bool host_known;
	bool own_published;
	uint instance;
	List{String} registry; // the watcher's registrations, when served: canonical ids
	List{ItemRecord*} items;
	List{Pending} pending;
	List{tray::Event} events;
	uint next_key;
	bool needs_resync;
	bool dirty;
	// The exported interfaces. The server keeps pointers into these, so they live in the backend.
	Interface[1] watcher_interfaces;
	Method[2] watcher_methods;
	Property[3] watcher_properties;
	Signal[4] watcher_signals;
	Interface[1] item_interfaces;
	Method[4] item_methods;
	Property[10] item_properties;
	Interface[1] menu_interfaces;
	Method[3] menu_methods;
	Property[3] menu_properties;
}

const Driver DRIVER = {
	.info = { "sni", "StatusNotifierItem and StatusNotifierWatcher on the session bus", 10 },
	.id = SNI,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// The session bus is the only thing this backend needs, so probing is opening it.
fn bool probe(Options* options)
{
	Connection connection;
	connection.init(mem);
	defer connection.free();
	if (catch connection.open_session()) return false;
	connection.close();
	return true;
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.set(
		Cap.MENU,
		availability::no(availability::Reason.DEGRADED, "Submenus are read when opened: call open_submenu first")
	);
	if (!options.publish_own)
	{
		capabilities.set(Cap.PUBLISH_OWN_ICON, availability::no(availability::Reason.DISABLED_BY_POLICY, "publish_own is false"));
		capabilities.set(Cap.OWN_MENU, availability::no(availability::Reason.DISABLED_BY_POLICY, "publish_own is false"));
	}
	SniBackend* backend = alloc::new(allocator, SniBackend, { .allocator = allocator, .publish_own = options.publish_own });
	backend.own = convert::copy_own(options.own, allocator);
	backend.registry.init(allocator);
	backend.items.init(allocator);
	backend.pending.init(allocator);
	backend.events.init(allocator);
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	SniBackend* backend = (SniBackend*)state;
	backend.registry.free();
	backend.items.free();
	backend.pending.free();
	backend.events.free();
	convert::free_own(backend.own, allocator);
	alloc::free(allocator, backend);
}

<* The worker's loop. Returns when the host stops. *>
fn void run(void* state, TrayHub* hub, Host{tray::Command}* host)
{
	SniBackend* backend = (SniBackend*)state;
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 2)) return;
	defer poller.free();
	tray::Command[BATCH] commands;
	while (!host.stopping())
	{
		if (!backend.connection_up) reconnect(backend, &poller);
		if (backend.connection_up)
		{
			if (catch backend.connection.process()) disconnect(backend, &poller);
		}
		usz count;
		do
		{
			count = host.mailbox().take_all(commands[..]);
			for (usz i = 0; i < count; i++) run_command(backend, commands[i]);
		}
		while (count == BATCH);
		if (backend.connection_up) process_pending(backend);
		publish(backend, hub);
		Duration wait = backend.pending.len() > 0 ? time::DURATION_ZERO : RETRY_INTERVAL;
		if (backend.connection_up && backend.connection.has_pending_output()) wait = time::ms(10);
		// Sleeps until the bus has data, a command is queued, or the retry interval passes.
		if (catch poller.wait(wait))
		{
			// TIMEOUT is the normal tick: nothing arrived, so the loop goes round again.
		}
	}
	disconnect(backend, &poller);
	fail_queued(host);
}

<*
 Connect, export our objects and attach them. Failures leave the backend disconnected, and
 the next pass tries again.
*>
fn void reconnect(SniBackend* backend, Poller* poller)
{
	backend.connection.init(backend.allocator);
	if (catch backend.connection.open_session())
	{
		backend.connection.free();
		return;
	}
	if (catch setup(backend, poller))
	{
		disconnect_connection(backend, poller);
		return;
	}
	backend.connection_up = true;
}

<* Export and register everything on a freshly opened connection. *>
fn void? setup(SniBackend* backend, Poller* poller)
{
	describe(backend);
	backend.server.init(backend.allocator);
	backend.server.export(WATCHER_PATH, backend.watcher_interfaces[..])!;
	if (backend.publish_own)
	{
		backend.server.export(ITEM_PATH, backend.item_interfaces[..])!;
		backend.server.export(OWN_MENU_PATH, backend.menu_interfaces[..])!;
	}
	backend.server.attach(&backend.connection);
	int fd = backend.connection.fd()!;
	poller.add({ .handle = (rt::Native)fd, .interest = { .readable = true }, .tag = CONNECTION_TAG })!;
	backend.instance++;
	int pid = (int)posix::getpid();
	backend.host_bus = string::format(backend.allocator, "%s%d-%d", HOST_NAME_PREFIX, pid, backend.instance);
	backend.own_bus = string::format(backend.allocator, "%s%d-%d", ITEM_NAME_PREFIX, pid, backend.instance);
	backend.own_item_id = string::format(backend.allocator, "%s%s", backend.own_bus, ITEM_PATH);
	backend.host_name = backend.connection.own_name(backend.host_bus, bus::NAME_DO_NOT_QUEUE, &on_name_acquired, null, backend)!;
	subscribe_watcher_owner(backend)!;
	if (backend.publish_own)
	{
		if (try own = backend.connection.own_name(backend.own_bus, bus::NAME_DO_NOT_QUEUE, &on_name_acquired, null, backend))
		{
			backend.own_item_name = own;
		}
	}
	attach_watcher(backend);
}

<* Release the names, then close and free the connection. The connection must be open for names to go. *>
fn void disconnect_connection(SniBackend* backend, Poller* poller)
{
	release_names(backend);
	backend.server.free();
	backend.connection.close();
	backend.connection.free();
	backend.connection_up = false;
	if (catch poller.remove(CONNECTION_TAG))
	{
		// The descriptor was never added to the poller.
	}
}

<* Drop the connection and everything learned from it. Safe when not connected. *>
fn void disconnect(SniBackend* backend, Poller* poller)
{
	if (!backend.connection_up) return;
	disconnect_connection(backend, poller);
	forget_records(backend);
	backend.registry.clear();
	backend.registry_subs_set = false;
	backend.watcher_watch_set = false;
	backend.watcher_present = false;
	backend.watcher_served = false;
	backend.host_known = false;
	backend.own_published = false;
	clear_pending(backend);
	backend.dirty = true;
}

// Release every owned name while the connection is still open.
fn void release_names(SniBackend* backend)
{
	if (backend.watcher_name)
	{
		if (catch backend.watcher_name.release()) {}
		backend.watcher_name = null;
	}
	if (backend.own_item_name)
	{
		if (catch backend.own_item_name.release()) {}
		backend.own_item_name = null;
	}
	if (backend.host_name)
	{
		if (catch backend.host_name.release()) {}
		backend.host_name = null;
	}
}

<* Name acquisition needs no bookkeeping: the holder is known from the name's `OwnedName`. *>
fn void on_name_acquired(void* context, String name)
{
}

// Runs one command from the mailbox and completes its operation. Frees the item name copy.
fn void run_command(SniBackend* backend, tray::Command command)
{
	if (command.kind == REFRESH)
	{
		for (sz i = 0; i < backend.items.len(); i++) read_everything(backend, backend.items[i]);
		backend.dirty = true;
		return;
	}
	ItemRecord* record = find_record_by_id(backend, command.item_id);
	if (record == null)
	{
		complete_fail(command.op, error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no tray item named '%s'", command.item_id));
	}
	else
	{
		execute(backend, record, command);
	}
	if (command.item_id.len > 0) alloc::free(backend.allocator, command.item_id.ptr);
}

// Performs one command on a known item. Its value is the operation's value (true when the item
// accepted, or when a submenu changed); its failure is the operation's failure.
fn bool? perform(SniBackend* b, ItemRecord* record, tray::Command command)
{
	switch (command.kind)
	{
		case ACTIVATE:
			call_position(b, record, "Activate", command.x, command.y)!;
			return true;
		case SECONDARY_ACTIVATE:
			call_position(b, record, "SecondaryActivate", command.x, command.y)!;
			return true;
		case CONTEXT_MENU:
			call_position(b, record, "ContextMenu", command.x, command.y)!;
			return true;
		case SCROLL:
			call_scroll(b, record, command.delta, command.horizontal)!;
			return true;
		case OPEN_SUBMENU:
			return open_submenu(b, record, command.menu_id);
		case CLICK_MENU:
			call_menu_click(b, record, command.menu_id)!;
			return true;
		case REFRESH:
			return error::UNSUPPORTED~;
	}
}

// Runs one command on a known item and completes its operation with the outcome.
fn void execute(SniBackend* b, ItemRecord* record, tray::Command command)
{
	bool? outcome = perform(b, record, command);
	if (catch err = outcome)
	{
		complete_fail(command.op, err);
		return;
	}
	complete_ok(command.op, outcome);
}

// Completes an operation with a value and drops the worker's reference. A null operation is a
// command nobody waits for (none exist today; kept so every path releases the same way).
fn void complete_ok(CommandOp* op, bool value)
{
	if (op == null) return;
	op.succeed(value);
	op.release();
}

// Completes an operation with a failure and drops the worker's reference.
fn void complete_fail(CommandOp* op, fault failure)
{
	if (op == null) return;
	op.fail(failure);
	op.release();
}

// Ends the commands still queued when the worker stops, so no caller waits forever.
fn void fail_queued(Host{tray::Command}* host)
{
	tray::Command[BATCH] commands;
	usz count;
	do
	{
		count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++)
		{
			if (commands[i].item_id.len > 0) alloc::free(mem, commands[i].item_id.ptr);
			complete_fail(commands[i].op, error::CANCELLED);
		}
	}
	while (count == BATCH);
}

// Stores an event for the next `publish`, which delivers it after the state it describes.
fn void queue_event(SniBackend* backend, tray::EventKind kind, String item_id, int menu_id, int x, int y)
{
	tray::Event event = { .kind = kind, .item_id = convert::copy_text(item_id, backend.allocator), .menu_id = menu_id, .x = x, .y = y };
	backend.events.push(event);
	backend.dirty = true;
}
