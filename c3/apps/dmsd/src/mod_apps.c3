<*
 The `apps` module: DMS's application-picker request and its MIME association reads.

 Methods: `apppicker.open` and `browser.open` (the same handler, `apppicker/handlers.go`:
 they publish `browser.open_requested` and answer `"ok"`), and `mime.getDefault` (by
 `mimeType`), `mime.appsForMime`, `mime.handlersForMime`, `mime.queryDefaults` and
 `mime.invalidate` (`mime/handlers.go`). Topic: `browser.open_requested` (`OpenEvent`).
 Refused: `mime.setDefault`, `mime.setDefaults` (no writer for mimeapps.list) and the
 `mime.getDefault` form that gives a `path` (no file-name to MIME-type lookup).

 Sources: `core/internal/server/apppicker/` and `mime/handlers.go` at DMS master
 (fetched from raw.githubusercontent.com on 2026-10-20; not pinned to a commit); the MIME rules are dankgo's
 `desktop/mime.go` (`StripMimeParams` at :154).
 The lookups run on `bleu::xdg::mime` and `bleu::apps`; deviations: docs/DMSD.md.

 Not advertised: DMS names the subscription `browser` (server.go:682) and labels its frames
 `browser.open_requested`. Bleu's subscriptions label a frame with its topic's own name, so
 a client that asks for `browser` would receive nothing. The capability is withheld until
 bleu_ipc can label one topic under another name. (The shell's own subscribe list was not
 read: its QML is outside the fetched files.)
*>
module dmsd::apps_mod;
import std::collections::list, std::collections::object, bleu::apps, bleu::error, bleu::ipc, bleu::json, bleu::xdg::dirs, bleu::xdg::mime, dmsd::contract, dmsd::wire, dmsd::params, dmsd::param_lists, dmsd::replies;

const String[1] TOPICS = { "browser.open_requested" };

// DMS's `OpenEvent` (apppicker/models.go:3-7) is sent under this name.
const String OPEN_TOPIC           = "browser.open_requested";
// The request type when the request names none (apppicker/handlers.go, GetOr).
const String DEFAULT_REQUEST_TYPE = "url";
// The reply to `apppicker.open` and `browser.open` (apppicker/handlers.go, Respond).
const String OPEN_REPLY           = "\"ok\"";
// Reply for `mime.getDefault {path}`: Bleu has no file-name to MIME-type lookup.
const String PATH_REASON          = "not supported: Bleu cannot find a file's MIME type from its name (no shared-mime-info glob table is read)";

// The refused methods: the writes to mimeapps.list.
const replies::Refusal[2] REFUSALS = {
	{
		.method = "mime.setDefault",
		.text = "not supported: Bleu reads mimeapps.list but has no writer; the default application cannot be set"
	},
	{
		.method = "mime.setDefaults",
		.text = "not supported: Bleu reads mimeapps.list but has no writer; default applications cannot be set"
	},
};

<* The module's runtime state. Allocated in `start`, freed in `stop`. *>
struct AppsModule
{
	apps::Apps* catalogue;
	ipc::Topic* open_topic;
}

<*
 dankgo's `desktop.StripMimeParams` (desktop/mime.go:154-159): the type before the first
 `;`, with surrounding spaces removed. "" when nothing is left.
*>
fn String strip_mime(String raw)
{
	usz end = raw.len;
	for (usz i = 0; i < raw.len; i++)
	{
		if (raw[i] == ';')
		{
			end = i;
			break;
		}
	}
	String head = raw[0:end];
	return head.trim();
}

<*
 A required MIME-type member, stripped (`mimeParam` in mime/handlers.go): the error for a
 missing or wrongly typed member is dankgo's; a member that strips to nothing is invalid.
*>
fn String? mime_param(Object* params, String key)
{
	String raw       = params::param_string(params, key)!;
	String canonical = strip_mime(raw);
	if (canonical.len == 0) return error::raise(
		error::INVALID_ARGUMENT,
		error::Domain.INTERNAL,
		0,
		"invalid '%s' parameter",
		key
	)~;
	return canonical;
}

// Sort `values` in place, byte-wise (insertion sort: the lists are short).
fn void sort_strings(String[] values) @private
{
	for (sz i = 1; i < values.len; i++)
	{
		String item = values[i];
		sz j        = i;
		while (j > 0 && values[j - 1].compare_to(item) > 0)
		{
			values[j] = values[j - 1];
			j--;
		}
		values[j] = item;
	}
}

<*
 The desktop IDs associated with `mime`, most preferred first (`xdg::mime::associated_applications`).
 A missing `mimeapps.list` or desktop file is not an error: it contributes nothing.
*>
fn String[] associated(Allocator allocator, String mime_type) @private
{
	dirs::ProcessEnvironment env = { };
	return mime::associated_applications(&env, allocator, mime_type);
}

// The default desktop ID for `mime`, or "" when none is associated (DMS's empty GetDefault).
fn String default_for(Allocator allocator, String mime_type) @private
{
	dirs::ProcessEnvironment env = { };
	if (try id = mime::default_application(&env, allocator, mime_type)) return id;
	return "";
}

// `{"mimeType":M,"desktopId":ID}` (mime/handlers.go defaultResult).
fn String? render_default(Allocator allocator, String mime_type, String desktop_id)
{
	wire::Line line;
	line.begin(allocator);
	line.writer.begin_object()!;
	wire::key_string(&line.writer, "mimeType", mime_type)!;
	wire::key_string(&line.writer, "desktopId", desktop_id)!;
	line.writer.end_object()!;
	return line.finish();
}

// `{"mimeType":M,"desktopIds":[...]}` (mime/handlers.go appsResult).
fn String? render_apps(Allocator allocator, String mime_type, String[] ids)
{
	wire::Line line;
	line.begin(allocator);
	line.writer.begin_object()!;
	wire::key_string(&line.writer, "mimeType", mime_type)!;
	wire::key_strings(&line.writer, "desktopIds", ids)!;
	line.writer.end_object()!;
	return line.finish();
}

// `{"target":..,"mimeType":..,"categories":..,"requestType":..}`: DMS's OpenEvent, `mimeType` and `categories` omitted when empty.
fn String? render_open_event(
	Allocator allocator,
	String target,
	String mime_type,
	String[] categories,
	String request_type
)
{
	wire::Line line;
	line.begin(allocator);
	json::JsonWriter* w = &line.writer;
	w.begin_object()!;
	wire::key_string(w, "target", target)!;
	if (mime_type.len > 0) wire::key_string(w, "mimeType", mime_type)!;
	if (categories.len > 0) wire::key_strings(w, "categories", categories)!;
	wire::key_string(w, "requestType", request_type)!;
	w.end_object()!;
	return line.finish();
}

// `apppicker.open` / `browser.open`: publish the request to the picker, then answer "ok".
fn void? open_request(AppsModule* m, ipc::Call* call) @private
{
	String target = "";
	if (try value = json::read::get_string(call.params, "target"))
	{
		target = value;
	}
	else if (try value = json::read::get_string(call.params, "url"))
	{
		target = value;
	}
	else
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "invalid target parameter")~;
	}
	String request_type = DEFAULT_REQUEST_TYPE;
	if (try value = json::read::get_string(call.params, "requestType")) request_type = value;
	String mime_type = "";
	if (try value = json::read::get_string(call.params, "mimeType")) mime_type = strip_mime(value);
	String[] categories = param_lists::strings(call.params, "categories", tmem);
	String line         = render_open_event(tmem, target, mime_type, categories, request_type)!;
	// Nobody listening is not an error: DMS answers "ok" whether or not the picker is open.
	if (catch m.open_topic.publish_event(line)) contract::note("%s not sent", OPEN_TOPIC);
	call.respond_raw(OPEN_REPLY);
}

fn void handle_open(void* context, ipc::Call* call)
{
	AppsModule* m = (AppsModule*)context;
	@pool()
	{
		if (catch open_request(m, call)) call.respond_error(contract::failure_text("failed to open the app picker"));
	};
}

// `mime.getDefault`: by `mimeType` (the form Bleu can answer) or by `path` (refused, see PATH_REASON).
fn void? get_default(ipc::Call* call) @private
{
	if (try value = call.params.get("mimeType"))
	{
		String mime_type = mime_param(call.params, "mimeType")!;
		call.respond_raw(render_default(tmem, mime_type, default_for(tmem, mime_type))!);
		return;
	}
	if (try value = call.params.get("path"))
	{
		call.respond_error(PATH_REASON);
		return;
	}
	return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "missing 'mimeType' or 'path' parameter")~;
}

fn void handle_get_default(void* context, ipc::Call* call)
{
	@pool()
	{
		if (catch get_default(
			call
		)) call.respond_error(contract::failure_text("failed to read the default application"));
	};
}

fn void? apps_for_mime(ipc::Call* call) @private
{
	String mime_type = mime_param(call.params, "mimeType")!;
	call.respond_raw(render_apps(tmem, mime_type, associated(tmem, mime_type))!);
}

fn void handle_apps_for_mime(void* context, ipc::Call* call)
{
	@pool()
	{
		if (catch apps_for_mime(
			call
		)) call.respond_error(contract::failure_text("failed to read the MIME associations"));
	};
}

// One DMS `handlerApp` (mime/handlers.go): `icon` is omitted when the entry has none.
fn void? write_handler(json::JsonWriter* w, apps::App* app)
{
	w.begin_object()!;
	wire::key_string(w, "id", app.id)!;
	wire::key_string(w, "name", app.name)!;
	if (app.icon.len > 0) wire::key_string(w, "icon", app.icon)!;
	w.end_object()!;
}

// `mime.handlersForMime`: the associated apps that the catalogue lists as graphical (no NoDisplay, no Terminal).
fn void? handlers_for_mime(AppsModule* m, ipc::Call* call) @private
{
	String mime_type                  = mime_param(call.params, "mimeType")!;
	String[] ids                      = associated(tmem, mime_type);
	apps::CatalogueSnapshot* snapshot = m.catalogue.latest()!;
	defer snapshot.release();
	wire::Line line;
	line.begin(tmem);
	line.writer.begin_object()!;
	wire::key_string(&line.writer, "mimeType", mime_type)!;
	line.writer.key("apps")!;
	line.writer.begin_array()!;
	foreach (id : ids)
	{
		foreach (&app : snapshot.value.apps)
		{
			if (app.id != id || app.no_display || app.terminal) continue;
			write_handler(&line.writer, app)!;
		}
	}
	line.writer.end_array()!;
	line.writer.end_object()!;
	call.respond_raw(line.finish()!);
}

fn void handle_handlers_for_mime(void* context, ipc::Call* call)
{
	AppsModule* m = (AppsModule*)context;
	@pool()
	{
		if (catch handlers_for_mime(
			m,
			call
		)) call.respond_error(contract::failure_text("failed to read the MIME associations"));
	};
}

// `mime.queryDefaults {mimeTypes}`: a map from each canonical type to its default, keys in byte order (Go's map encoding).
fn void? query_defaults(ipc::Call* call) @private
{
	if (catch param_lists::array_member(
		call.params,
		"mimeTypes"
	)) return error::raise(
		error::INVALID_ARGUMENT,
		error::Domain.INTERNAL,
		0,
		"missing or invalid 'mimeTypes' parameter"
	)~;
	String[] raw = param_lists::strings(call.params, "mimeTypes", tmem);
	List{String} canonical;
	canonical.init(tmem);
	foreach (value : raw)
	{
		String stripped = strip_mime(value);
		if (stripped.len > 0) canonical.push(stripped);
	}
	if (canonical.len() == 0) return error::raise(
		error::INVALID_ARGUMENT,
		error::Domain.INTERNAL,
		0,
		"no valid mime types provided"
	)~;
	String[] types = canonical.to_aligned_array(tmem);
	sort_strings(types);
	wire::Line line;
	line.begin(tmem);
	line.writer.begin_object()!;
	line.writer.key("defaults")!;
	line.writer.begin_object()!;
	for (sz i = 0; i < types.len; i++)
	{
		if (i > 0 && types[i] == types[i - 1]) continue;
		wire::key_string(&line.writer, types[i], default_for(tmem, types[i]))!;
	}
	line.writer.end_object()!;
	line.writer.end_object()!;
	call.respond_raw(line.finish()!);
}

fn void handle_query_defaults(void* context, ipc::Call* call)
{
	@pool()
	{
		if (catch query_defaults(
			call
		)) call.respond_error(contract::failure_text("failed to read the default applications"));
	};
}

// `mime.invalidate`: Bleu reads the MIME files on every request and keeps no cache, so there is nothing to drop.
fn void handle_invalidate(void* context, ipc::Call* call)
{
	@pool()
	{
		if (catch wire::respond_success(call, "")) call.respond_error(contract::failure_text("failed to answer"));
	};
}

fn void handle_refused(void* context, ipc::Call* call)
{
	replies::answer(REFUSALS[..], call);
}

<* Start the apps module, or report why not and return false. *>
fn bool start(contract::Context* context, contract::Module* self)
{
	apps::Apps* catalogue;
	if (try opened = apps::open(context.allocator))
	{
		catalogue = opened;
	}
	else
	{
		contract::warn("apps: not started: no application catalogue could be opened");
		return false;
	}
	AppsModule* m = alloc::new(context.allocator, AppsModule);
	m.catalogue = catalogue;
	m.open_topic = context.server.register_topic(OPEN_TOPIC)!!;
	context.server.register_method("apppicker.open", &handle_open, m)!!;
	context.server.register_method("browser.open", &handle_open, m)!!;
	context.server.register_method("mime.getDefault", &handle_get_default, m)!!;
	context.server.register_method("mime.appsForMime", &handle_apps_for_mime, m)!!;
	context.server.register_method("mime.handlersForMime", &handle_handlers_for_mime, m)!!;
	context.server.register_method("mime.queryDefaults", &handle_query_defaults, m)!!;
	context.server.register_method("mime.invalidate", &handle_invalidate, m)!!;
	replies::register_all(context.server, REFUSALS[..], &handle_refused)!!;
	self.state = m;
	return true;
}

<* Stop the module: the catalogue is closed. The server has stopped already. *>
fn void stop(contract::Context* context, contract::Module* self)
{
	AppsModule* m = (AppsModule*)self.state;
	m.catalogue.close();
	alloc::free(context.allocator, m);
}

<*
 The module's descriptor for `main`. It advertises no capability (see the note above):
 DMS's `browser` is withheld until the subscription can name it.
*>
const contract::Module DESCRIPTOR = {
	.name = "apps",
	.start = &start,
	.stop = &stop,
	.topics = TOPICS[..],
};

fn contract::Module descriptor() => DESCRIPTOR;