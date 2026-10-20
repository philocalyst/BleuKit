<*
 The Linux configured-layout backend: systemd-localed on the system bus (org.freedesktop.locale1).

 Read-only and used where no compositor runs (a console session, a login screen). It reports the layouts the
 system is configured with, not the one a session has active: `current` is absent and switching is refused,
 since changing a layout needs a running compositor (localed's own setters change the configuration, not the
 live layout, and are not offered here).

 The state is read with `GetAll` on `org.freedesktop.locale1` (X11Layout, X11Variant) and refreshed when
 `PropertiesChanged` arrives or the poll interval passes. A missing name means the backend is not offered
 (`probe` is false), so a session without localed never shows an empty list as if it were the configuration.

 Source: systemd man page org.freedesktop.locale1
 (https://www.freedesktop.org/software/systemd/man/latest/org.freedesktop.locale1.html)
 for the interface and property names; systemd src/locale/localectl.c for the bus name and object path.
*>
module bleu::input::linux_locale1 @feat(LINUX);
import std::time, bleu::availability, bleu::dbus::connection, bleu::dbus::proxy, bleu::dbus::value, bleu::error, bleu::input, bleu::input::locale1_convert, bleu::observe, bleu::rt::poller, bleu::rt::worker, bleu::service;

const String LOCALE1_NAME      = "org.freedesktop.locale1";
const String LOCALE1_PATH      = "/org/freedesktop/locale1";
const String LOCALE1_INTERFACE = "org.freedesktop.locale1";

// The poller tag of the bus connection. The wake-up is not tagged (see bleu_rt).
const usz CONNECTION_TAG = 1;
// Commands the worker takes in one pass.
const usz COMMAND_BATCH  = 8;

<* The backend's state. `changed` is set by the signal handlers and read after the bus has been processed. *>
struct Locale1Backend
{
	Allocator allocator;
	Duration poll;
	Connection connection;
	bool connected;
	bool changed;
}

const Driver DRIVER = {
	.info = { "locale1", "configured layouts from systemd-localed on the system bus (org.freedesktop.locale1)", 10 },
	.id = Backend.LOCALE1,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

<* Whether localed's name has an owner on the system bus. The connection used for the check is closed again. *>
fn bool probe(Options* options)
{
	Connection connection;
	connection.init(mem);
	defer connection.free();
	if (catch connection.open_system()) return false;
	defer connection.close();
	if (try owned = connection.name_has_owner(LOCALE1_NAME)) return owned;
	return false;
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.set(
		Cap.LIST,
		availability::no(
			availability::Reason.DEGRADED,
			"The configured layouts of the system, not the ones a session has active"
		)
	);
	capabilities.set(
		Cap.CURRENT,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"systemd-localed does not report the layout a session has active"
		)
	);
	capabilities.set(
		Cap.SWITCH,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"Changing the active layout needs a compositor; localed holds the configuration only"
		)
	);
	Locale1Backend* backend = alloc::new(allocator, Locale1Backend, { .allocator = allocator, .poll = options.poll });
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

// PropertiesChanged on the localed object: read the configuration again.
fn void on_properties(void* context, proxy::PropertyChange* change) @local
{
	Locale1Backend* backend = (Locale1Backend*)context;
	backend.changed = true;
}

<*
 Open the system bus, watch the object's properties and register the connection with the poller. On failure
 nothing stays open.

 @return? error::UNAVAILABLE : "when the system bus cannot be reached"
*>
fn void? connect(Locale1Backend* backend, Poller* poller)
{
	backend.connection.init(backend.allocator);
	if (catch err = backend.connection.open_system())
	{
		backend.connection.free();
		return err~;
	}
	if (catch err = subscribe(backend))
	{
		backend.connection.close();
		backend.connection.free();
		return err~;
	}
	int fd = backend.connection.fd()!;
	if (catch err = poller.add({ .handle = (rt::Native)fd, .interest = { .readable = true }, .tag = CONNECTION_TAG }))
	{
		backend.connection.close();
		backend.connection.free();
		return err~;
	}
	backend.connected = true;
}

<* Close the connection and take it out of the poller. Safe when not connected. *>
fn void disconnect(Locale1Backend* backend, Poller* poller)
{
	if (!backend.connected) return;
	backend.connected = false;
	if (catch poller.remove(CONNECTION_TAG))
	{
		// Not registered: nothing to remove.
	}
	backend.connection.close();
	backend.connection.free();
}

<* The watch on localed's properties. It ends with the connection. *>
fn void? subscribe(Locale1Backend* backend)
{
	proxy::Proxy root = proxy::for_object(&backend.connection, LOCALE1_NAME, LOCALE1_PATH, LOCALE1_INTERFACE)!;
	if (catch err = root.watch_properties(&on_properties, backend, false)) return err~;
}

<*
 The configured layouts, read now. Callers hold a `@pool()`: the property values are copied into tmem.

 @return? error::UNAVAILABLE : "when the connection is down"
*>
fn State? read_configured(Locale1Backend* backend, Allocator allocator) @private
{
	if (!backend.connected) return error::UNAVAILABLE~;
	State state;
	@pool()
	{
		proxy::Proxy root = proxy::for_object(&backend.connection, LOCALE1_NAME, LOCALE1_PATH, LOCALE1_INTERFACE)!;
		Value props       = root.get_all_properties(tmem)!;
		String layout     = prop_text(props, "X11Layout", tmem);
		String variant    = prop_text(props, "X11Variant", tmem);
		state.layouts = locale1_convert::layouts_from(layout, variant, allocator);
	};
	state.can_switch = false;
	return state;
}

<* A string property copied into tmem; "" when absent or not a string. *>
fn String prop_text(Value props, String name, Allocator allocator) @private
{
	if (try v = props.dict_get(name))
	{
		if (try text = v.as_string()) return text.copy(allocator);
	}
	return "";
}

<* Publish the configuration now. An unreadable localed is an empty state: nothing is known. *>
fn void refresh(Locale1Backend* backend, InputHub* hub) @private
{
	Snapshot{State}* snapshot = hub.begin();
	if (try state = read_configured(backend, snapshot.allocator()))
	{
		snapshot.value = state;
	}
	else
	{
		snapshot.value = { };
	}
	input::publish_state(hub, snapshot);
}

fn void run(void* state, InputHub* hub, Host{Command}* host)
{
	Locale1Backend* backend = (Locale1Backend*)state;
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	if (catch connect(backend, &poller))
	{
		// localed is not reachable yet: each poll tick tries again, and the state stays empty.
	}
	refresh(backend, hub);
	Command[COMMAND_BATCH] commands;
	while (!host.stopping())
	{
		// A timeout is normal: the configuration is read again at each poll interval.
		bool timed_out = false;
		if (catch poller.wait(backend.poll))
		{
			timed_out = true;
		}
		if (backend.connected)
		{
			if (catch backend.connection.process())
			{
				// The bus went away: the next tick reconnects.
				disconnect(backend, &poller);
				backend.changed = true;
			}
		}
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++)
		{
			// Nothing here can switch a layout: the state says so, so the service refuses the request before it
			// gets here. The worker still completes the operation, rather than leaving it pending.
			if (commands[i].kind == CommandKind.SWITCH_TO)
			{
				input::fail_switch(
					commands[i].operation,
					error::raise(
						error::UNSUPPORTED,
						error::Domain.INTERNAL,
						0,
						"systemd-localed cannot change the active layout"
					)
				);
			}
		}
		if (!backend.connected)
		{
			if (catch connect(backend, &poller))
			{
				// Still unreachable; the empty state stands.
			}
		}
		if (timed_out || count > 0 || backend.changed)
		{
			backend.changed = false;
			refresh(backend, hub);
		}
	}
	input::fail_queued(host);
	disconnect(backend, &poller);
}