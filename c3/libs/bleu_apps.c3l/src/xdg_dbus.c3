<*
 D-Bus activation of desktop entries with `DBusActivatable=true`.

 The worker opens the session bus once, on its own thread (`bleu::dbus`
 connections are owned by the thread that made them). An activatable app is
 started by calling `org.freedesktop.Application` on the bus name made from its
 desktop file ID, at the object path made from that name: `Activate` with the
 startup id and activation token, `Open` with the URIs, `ActivateAction` for a
 desktop action. If the bus does not answer (no service, no bus), the launch
 falls back to the `Exec` line, as GIO does when `Exec` is present.

 Sources: the Desktop Entry specification's D-Bus Activation section (method
 signatures, the `desktop-startup-id` and `activation-token` keys, the object
 path rule), and GLib's `gdesktopappinfo.c` (`object_path_from_appid`, the
 platform data keys), as cited in `docs/research/apps_sysinfo_secrets_appearance.md`.
*>
module bleu::apps::xdg_desktop @feat(LINUX);
import bleu::apps, bleu::dbus::connection, bleu::dbus::message, bleu::dbus::proxy, bleu::dbus::value, bleu::dbus::marshal, bleu::error, std::collections::list;

const String APPLICATION_INTERFACE = "org.freedesktop.Application";
const String KEY_STARTUP_ID        = "desktop-startup-id";
const String KEY_ACTIVATION_TOKEN  = "activation-token";

<*
 Open the session bus on the calling (worker) thread.

 @return "true when the bus answered and the connection is open"
*>
fn bool open_bus(XdgBackend* backend)
{
	backend.bus.init(mem);
	// Without a session bus there is no D-Bus activation; the launch uses Exec.
	if (catch err = backend.bus.open_session())
	{
		backend.bus.free();
		return false;
	}
	return true;
}

<*
 Activate `app` (or its action) over the bus.

 @return? error::UNAVAILABLE : "The bus name has no owner and cannot be activated"
 @return? error::PROTOCOL : "The desktop file ID does not make a valid bus name or object path"
*>
fn Launched? dbus_launch(XdgBackend* backend, App* app, AppAction* action, LaunchRequest* request)
{
	String stem            = apps::desktop_id_stem(app.id);
	String object_path     = object_path_for(stem);
	proxy::Proxy remote    = proxy::for_object(&backend.bus, stem, object_path, APPLICATION_INTERFACE)!;
	Value platform         = platform_data(request)!;
	message::Message* call = build_call(&remote, action, request, platform)!;
	defer call.release();
	message::Message* reply = backend.bus.call(call)!;
	defer reply.release();
	return { .route = DBUS_ACTIVATE, .pid = 0 };
}

// The method call for an action, for URIs, or for a plain activation, with its arguments written.
fn message::Message*? build_call(proxy::Proxy* remote, AppAction* action, LaunchRequest* request, Value platform) @local
{
	if (action != null)
	{
		Value name              = value::str(tmem, action.id)!;
		Value[] parameters      = { };
		Value empty             = value::array(tmem, "v", parameters)!;
		message::Message* call  = remote.new_call(tmem, "ActivateAction")!;
		marshal::Writer* writer = call.body_writer("sava{sv}")!;
		writer.append_value(name)!;
		writer.append_value(empty)!;
		writer.append_value(platform)!;
		return call;
	}
	if (request.uris.len > 0 || request.files.len > 0)
	{
		Value uris              = uri_array(request)!;
		message::Message* call  = remote.new_call(tmem, "Open")!;
		marshal::Writer* writer = call.body_writer("asa{sv}")!;
		writer.append_value(uris)!;
		writer.append_value(platform)!;
		return call;
	}
	message::Message* call  = remote.new_call(tmem, "Activate")!;
	marshal::Writer* writer = call.body_writer("a{sv}")!;
	writer.append_value(platform)!;
	return call;
}

<*
 The URIs of a request as an `as`: the given URIs, then the files as `file://`
 URIs. The files are not percent-encoded in this version (see the README).
*>
fn Value? uri_array(LaunchRequest* request) @local
{
	List{Value} items;
	items.tinit();
	foreach (uri : request.uris) items.push(value::str(tmem, uri)!);
	foreach (file : request.files) items.push(value::str(tmem, string::tformat("file://%s", file))!);
	return value::array(tmem, "s", items.to_tarray());
}

<*
 The platform data of the call: `desktop-startup-id` and `activation-token`, when
 the request carries them, as an `a{sv}`.
*>
fn Value? platform_data(LaunchRequest* request) @local
{
	List{Value} entries;
	entries.tinit();
	if (request.startup_id.len > 0) entries.push(entry(KEY_STARTUP_ID, request.startup_id)!);
	if (request.activation_token.len > 0) entries.push(entry(KEY_ACTIVATION_TOKEN, request.activation_token)!);
	return value::array(tmem, "{sv}", entries.to_tarray());
}

// One `{sv}` dictionary entry: a string key and a string variant.
fn Value? entry(String key, String text) @local
{
	Value name  = value::str(tmem, key)!;
	Value inner = value::str(tmem, text)!;
	return value::dict_entry(tmem, name, value::variant(tmem, inner));
}

<*
 The object path of a bus name: `/` followed by the name with `.` as `/` and
 `-` as `_` (the rule the Desktop Entry specification gives for D-Bus activation).
*>
fn String object_path_for(String stem) @local
{
	DString path;
	path.init(tmem);
	path.append_char('/');
	foreach (c : stem)
	{
		if (c == '.')
		{
			path.append_char('/');
		}
		else if (c == '-')
		{
			path.append_char('_');
		}
		else
		{
			path.append_char(c);
		}
	}
	return path.str_view();
}