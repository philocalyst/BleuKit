<*
 niri's IPC, pure part: JSON-lines replies become a `compositor::Model`, event
 lines become `RawEvent`s that `apply` folds into a retained model, and the
 request lines for actions are built here.

 Source: the `niri-ipc` crate, version 26.4.0 (static.crates.io), `src/lib.rs`
 (`Request`, `Response`, `Event`, `Action`, `Window`, `Workspace`, `Output`,
 `KeyboardLayouts`, `LogicalOutput`, `WorkspaceReferenceArg`, `LayoutSwitchTarget`)
 and `src/socket.rs` (one JSON line per request, one JSON line per reply, the
 reply type `Result<Response, String>` serialised as `{"Ok": ...}` or `{"Err": ...}`).
 The 25.11.0 variants that matter here are identical; 26.4.0 only adds the `Cast*`
 events and the `Casts` response, which this library ignores. Socket I/O is in
 `niri_io.c3`.
*>
module bleu::compositor::niri;
import std::collections::object, std::collections::maybe, bleu::error, bleu::compositor, bleu::compositor::backend, bleu::compositor::wire;

<*
 The replies `build` reads. Each is the payload of a reply, not the envelope.
*>
struct Replies
{
	Object* workspaces; // `Workspaces`: array
	Object* windows;    // `Windows`: array
	Object* outputs;    // `Outputs`: object keyed by output name
	Object* layouts;    // `KeyboardLayouts`: object with `names` and `current_idx`
}

<*
 Unwrap a reply envelope: `{"Ok": value}` gives `value`, `{"Err": message}` gives a
 BACKEND_FAILURE in the COMPOSITOR domain with the message.

 @param what : "The request, for the error message"
 @return? error::PROTOCOL : "The reply has neither `Ok` nor `Err`"
 @return? error::BACKEND_FAILURE : "niri refused the request; the message is in the detail"
*>
fn Object*? unwrap(Object* reply, String what)
{
	Object*? ok = wire::member(reply, "Ok");
	if (catch err = ok)
	{
		if (!wire::present(reply, "Err")) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "niri reply for %s has neither Ok nor Err", what)~;
		String message = wire::peek(reply, "Err", "no message");
		return error::raise(error::BACKEND_FAILURE, error::Domain.COMPOSITOR, 0, "niri refused %s: %s", what, message)~;
	}
	return ok;
}

<*
 Build the model from one set of replies.

 @param allocator : "Long-lived allocator for the model (not tmem)"
 @return? error::PROTOCOL : "A list or object reply has the wrong shape"
*>
fn compositor::Model? build(Allocator allocator, Replies replies)
{
	if (!replies.workspaces.is_array() || !replies.windows.is_array() || !replies.outputs.is_map() || !replies.layouts.is_map())
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "niri: a reply has the wrong shape")~;
	}
	compositor::Workspace[] workspaces = build_workspaces(replies.workspaces, allocator);
	return {
		.kind = compositor::Kind.NIRI,
		.workspaces = workspaces,
		.windows = build_windows(replies.windows, workspaces, allocator),
		.outputs = build_outputs(replies.outputs, workspaces, allocator),
		.layouts = build_layouts(replies.layouts, allocator),
	};
}

fn compositor::Workspace[] build_workspaces(Object* list, Allocator allocator) @private
{
	sz count = wire::length(list);
	compositor::Workspace[] out = alloc::new_array(allocator, compositor::Workspace, count);
	for (sz i = 0; i < count; i++) out[i] = workspace_of(wire::item(list, i), allocator);
	return out;
}

fn compositor::Workspace workspace_of(Object* workspace, Allocator allocator) @private
{
	return {
		.id = id_text(wire::integer_member(workspace, "id"), allocator),
		.name = wire::text_member(workspace, "name", allocator),
		.output = wire::text_member(workspace, "output", allocator),
		.active = wire::flag_member(workspace, "is_active"),
		.focused = wire::flag_member(workspace, "is_focused"),
		.urgent = { .value = wire::flag_member(workspace, "is_urgent"), .has_value = true },
	};
}

fn compositor::Window[] build_windows(Object* list, compositor::Workspace[] workspaces, Allocator allocator) @private
{
	sz count = wire::length(list);
	compositor::Window[] out = alloc::new_array(allocator, compositor::Window, count);
	for (sz i = 0; i < count; i++) out[i] = window_of(wire::item(list, i), workspaces, allocator);
	return out;
}

// A niri window reports no absolute position and no fullscreen or maximized
// state, so those fields stay absent.
fn compositor::Window window_of(Object* window, compositor::Workspace[] workspaces, Allocator allocator) @private
{
	Maybe{long} workspace = wire::optional_integer(window, "workspace_id");
	String workspace_id = workspace.has_value ? id_text(workspace.value, allocator) : "";
	return {
		.id = id_text(wire::integer_member(window, "id"), allocator),
		.title = wire::text_member(window, "title", allocator),
		.app_id = wire::text_member(window, "app_id", allocator),
		.pid = pid_of(window),
		.workspace_id = workspace_id,
		.output = output_of_workspace(workspaces, workspace_id, allocator),
		.focused = wire::flag_member(window, "is_focused"),
		.floating = wire::flag_member(window, "is_floating"),
		.fullscreen = {},
		.maximized = {},
		.urgent = { .value = wire::flag_member(window, "is_urgent"), .has_value = true },
		.geometry = {},
	};
}

fn Maybe{int} pid_of(Object* window) @private
{
	Maybe{long} pid = wire::optional_integer(window, "pid");
	if (!pid.has_value) return {};
	return { .value = (int)pid.value, .has_value = true };
}

fn String output_of_workspace(compositor::Workspace[] workspaces, String id, Allocator allocator) @private
{
	for (sz i = 0; i < workspaces.len; i++)
	{
		if (workspaces[i].id == id) return workspaces[i].output.copy(allocator);
	}
	return "";
}

// Outputs come as an object keyed by name. Each has `logical` (null when the
// output is off) with the position and scale of the output.
fn compositor::Output[] build_outputs(Object* outputs, compositor::Workspace[] workspaces, Allocator allocator) @private
{
	String[] names = outputs.map.tkeys();
	compositor::Output[] out = alloc::new_array(allocator, compositor::Output, names.len);
	for (sz i = 0; i < names.len; i++)
	{
		Object* output = wire::member(outputs, names[i]) ?? null;
		String name = names[i];
		String active_workspace = "";
		bool focused = false;
		for (sz j = 0; j < workspaces.len; j++)
		{
			if (workspaces[j].output != name) continue;
			if (workspaces[j].active) active_workspace = workspaces[j].id;
			if (workspaces[j].focused) focused = true;
		}
		out[i] = {
			.name = name.copy(allocator),
			.geometry = logical_geometry(output),
			.scale = logical_scale(output),
			.active_workspace = active_workspace.copy(allocator),
			.focused = focused,
		};
	}
	return out;
}

fn Maybe{Rect} logical_geometry(Object* output) @private
{
	Object*? logical = wire::member(output, "logical");
	if (catch err = logical) return {};
	if (!logical.is_map()) return {};
	Rect rect = {
		.x = (int)wire::integer_member(logical, "x"),
		.y = (int)wire::integer_member(logical, "y"),
		.width = (int)wire::integer_member(logical, "width"),
		.height = (int)wire::integer_member(logical, "height"),
	};
	return { .value = rect, .has_value = true };
}

fn Maybe{double} logical_scale(Object* output) @private
{
	Object*? logical = wire::member(output, "logical");
	if (catch err = logical) return {};
	return wire::number_member(logical, "scale");
}

fn compositor::KeyboardLayouts build_layouts(Object* layouts, Allocator allocator) @private
{
	Object*? list = wire::member(layouts, "names");
	if (catch err = list) return {};
	sz count = wire::length(list);
	String[] names = alloc::new_array(allocator, String, count);
	for (sz i = 0; i < count; i++) names[i] = wire::text_element(list, i, allocator);
	Maybe{long} current = wire::optional_integer(layouts, "current_idx");
	String current_name = "";
	if (current.has_value && current.value >= 0 && current.value < (long)count) current_name = names[current.value];
	return {
		.names = names,
		.current = current.has_value ? { .value = (int)current.value, .has_value = true } : {},
		.current_name = current_name.copy(allocator),
	};
}

<*
 Split one event line into its variant name and keep the line as the payload.
 `apply` reads the body of the variant from the payload.

 @return? error::PROTOCOL : "The line is not a JSON object with one variant"
*>
fn backend::RawEvent? parse_event(String line)
{
	Object*? root = wire::parse_document(line, "niri event");
	if (catch err = root) return err~;
	if (!root.is_map() || root.map.len() != 1) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "niri event is not a single variant")~;
	String[] names = root.map.tkeys();
	return { .name = names[0].copy(tmem), .payload = line };
}

<*
 Fold one niri event into `model`. Workspace and window lists are replaced by the
 event that carries them; single changes (focus, urgency, layouts) are applied in
 place; the configuration reloading asks for a snapshot.

 @param allocator : "Allocator for new arrays and strings in `model` (not tmem)"
*>
fn backend::Refresh apply(compositor::Model* model, Allocator allocator, backend::RawEvent event)
{
	@pool()
	{
		Object*? root = wire::parse_document(event.payload, "niri event");
		if (catch err = root) return REFRESH_NEEDED;
		Object*? body = wire::member(root, event.name);
		if (catch err = body) return REFRESH_NEEDED;
		switch
		{
			case event.name == "WorkspacesChanged": return workspaces_changed(model, allocator, body);
			case event.name == "WorkspaceUrgencyChanged": return workspace_urgency(model, body);
			case event.name == "WorkspaceActivated": return workspace_activated(model, body);
			case event.name == "WindowsChanged": return windows_changed(model, allocator, body);
			case event.name == "WindowOpenedOrChanged": return window_opened(model, allocator, body);
			case event.name == "WindowClosed": return window_closed(model, allocator, body);
			case event.name == "WindowFocusChanged": return window_focused(model, body);
			case event.name == "WindowUrgencyChanged": return window_urgency(model, body);
			case event.name == "KeyboardLayoutsChanged": return layouts_changed(model, allocator, body);
			case event.name == "KeyboardLayoutSwitched": return layout_switched(model, allocator, body);
			case event.name == "ConfigLoaded": return REFRESH_NEEDED;
			default: return NONE;
		}
	};
}

fn backend::Refresh workspaces_changed(compositor::Model* model, Allocator allocator, Object* body) @private
{
	Object*? list = wire::array_member(body, "workspaces");
	if (catch err = list) return REFRESH_NEEDED;
	model.workspaces = build_workspaces(list, allocator);
	relabel_windows(model, allocator);
	return UPDATED;
}

// After the workspace list changed, windows take their output from it again.
fn void relabel_windows(compositor::Model* model, Allocator allocator) @private
{
	for (sz i = 0; i < model.windows.len; i++)
	{
		model.windows[i].output = output_of_workspace(model.workspaces, model.windows[i].workspace_id, allocator);
	}
}

fn backend::Refresh workspace_urgency(compositor::Model* model, Object* body) @private
{
	sz target = workspace_index(model, id_member(body, "id"));
	if (target < 0) return REFRESH_NEEDED;
	model.workspaces[target].urgent = { .value = wire::flag_member(body, "urgent"), .has_value = true };
	return UPDATED;
}

// Activating a workspace shows it on its output and, when `focused`, moves focus to it.
fn backend::Refresh workspace_activated(compositor::Model* model, Object* body) @private
{
	String id = id_member(body, "id");
	sz target = workspace_index(model, id);
	if (target < 0) return REFRESH_NEEDED;
	bool focused = wire::flag_member(body, "focused");
	String output = model.workspaces[target].output;
	for (sz i = 0; i < model.workspaces.len; i++)
	{
		compositor::Workspace* workspace = &model.workspaces[i];
		if (workspace.output == output) workspace.active = workspace.id == id;
		if (focused) workspace.focused = workspace.id == id;
	}
	return UPDATED;
}

fn backend::Refresh windows_changed(compositor::Model* model, Allocator allocator, Object* body) @private
{
	Object*? list = wire::array_member(body, "windows");
	if (catch err = list) return REFRESH_NEEDED;
	model.windows = build_windows(list, model.workspaces, allocator);
	return UPDATED;
}

fn backend::Refresh window_opened(compositor::Model* model, Allocator allocator, Object* body) @private
{
	Object*? window = wire::object_member(body, "window");
	if (catch err = window) return REFRESH_NEEDED;
	compositor::Window fresh = window_of(window, model.workspaces, allocator);
	sz target = window_index(model, fresh.id);
	if (target >= 0)
	{
		model.windows[target] = fresh;
		return UPDATED;
	}
	sz count = model.windows.len;
	compositor::Window[] windows = alloc::new_array(allocator, compositor::Window, count + 1);
	for (sz i = 0; i < count; i++) windows[i] = model.windows[i];
	windows[count] = fresh;
	model.windows = windows;
	return UPDATED;
}

fn backend::Refresh window_closed(compositor::Model* model, Allocator allocator, Object* body) @private
{
	sz target = window_index(model, id_member(body, "id"));
	if (target < 0) return NONE;
	sz count = model.windows.len;
	compositor::Window[] windows = alloc::new_array(allocator, compositor::Window, count - 1);
	sz out = 0;
	for (sz i = 0; i < count; i++)
	{
		if (i == target) continue;
		windows[out++] = model.windows[i];
	}
	model.windows = windows;
	return UPDATED;
}

// `id` is null when no window has focus.
fn backend::Refresh window_focused(compositor::Model* model, Object* body) @private
{
	if (!wire::present(body, "id"))
	{
		clear_focus(model);
		return UPDATED;
	}
	sz target = window_index(model, id_member(body, "id"));
	if (target < 0) return REFRESH_NEEDED;
	clear_focus(model);
	model.windows[target].focused = true;
	return UPDATED;
}

fn backend::Refresh window_urgency(compositor::Model* model, Object* body) @private
{
	sz target = window_index(model, id_member(body, "id"));
	if (target < 0) return REFRESH_NEEDED;
	model.windows[target].urgent = { .value = wire::flag_member(body, "urgent"), .has_value = true };
	return UPDATED;
}

fn backend::Refresh layouts_changed(compositor::Model* model, Allocator allocator, Object* body) @private
{
	Object*? layouts = wire::object_member(body, "keyboard_layouts");
	if (catch err = layouts) return REFRESH_NEEDED;
	model.layouts = build_layouts(layouts, allocator);
	return UPDATED;
}

fn backend::Refresh layout_switched(compositor::Model* model, Allocator allocator, Object* body) @private
{
	Maybe{long} index = wire::optional_integer(body, "idx");
	if (!index.has_value || index.value < 0 || index.value >= (long)model.layouts.names.len) return REFRESH_NEEDED;
	model.layouts.current = { .value = (int)index.value, .has_value = true };
	model.layouts.current_name = model.layouts.names[index.value].copy(allocator);
	return UPDATED;
}

// Ids are numbers in niri's JSON; they are kept as text like every other id.
fn String id_member(Object* obj, String key) @private
{
	return id_text(wire::integer_member(obj, key, -1), tmem);
}

fn String id_text(long id, Allocator allocator) @private => string::tformat("%d", id).copy(allocator);

fn sz window_index(compositor::Model* model, String id) @private
{
	for (sz i = 0; i < model.windows.len; i++)
	{
		if (model.windows[i].id == id) return i;
	}
	return -1;
}

fn sz workspace_index(compositor::Model* model, String id) @private
{
	for (sz i = 0; i < model.workspaces.len; i++)
	{
		if (model.workspaces[i].id == id) return i;
	}
	return -1;
}

fn void clear_focus(compositor::Model* model) @private
{
	for (sz i = 0; i < model.windows.len; i++) model.windows[i].focused = false;
}

// Requests, one JSON line each. The ids are numbers, checked by the caller.

<* The `EventStream` request: after its `Ok` reply the connection carries events. *>
const String REQUEST_EVENT_STREAM = "\"EventStream\"";
<* The `Workspaces` request. *>
const String REQUEST_WORKSPACES = "\"Workspaces\"";
<* The `Windows` request. *>
const String REQUEST_WINDOWS = "\"Windows\"";
<* The `Outputs` request. *>
const String REQUEST_OUTPUTS = "\"Outputs\"";
<* The `KeyboardLayouts` request. *>
const String REQUEST_KEYBOARD_LAYOUTS = "\"KeyboardLayouts\"";

<* `Action::FocusWindow`. *>
fn String focus_window_request(String id) => string::tformat("{\"Action\":{\"FocusWindow\":{\"id\":%s}}}", id);
<* `Action::CloseWindow`. *>
fn String close_window_request(String id) => string::tformat("{\"Action\":{\"CloseWindow\":{\"id\":%s}}}", id);
<* `Action::FocusWorkspace` with a numeric id reference. *>
fn String switch_workspace_request(String id) => string::tformat("{\"Action\":{\"FocusWorkspace\":{\"reference\":{\"Id\":%s}}}}", id);
<* `Action::MoveWindowToWorkspace`; focus stays where it was. *>
fn String move_window_request(String window_id, String workspace_id) => string::tformat("{\"Action\":{\"MoveWindowToWorkspace\":{\"window_id\":%s,\"reference\":{\"Id\":%s},\"focus\":false}}}", window_id, workspace_id);
<* `Action::SwitchLayout` with `LayoutSwitchTarget::Index`. *>
fn String set_layout_request(uint index) => string::tformat("{\"Action\":{\"SwitchLayout\":{\"layout\":{\"Index\":%d}}}}", index);
<* `Action::ToggleWindowFloating`. *>
fn String toggle_floating_request(String id) => string::tformat("{\"Action\":{\"ToggleWindowFloating\":{\"id\":%s}}}", id);
<* `Action::FullscreenWindow`, which toggles. *>
fn String toggle_fullscreen_request(String id) => string::tformat("{\"Action\":{\"FullscreenWindow\":{\"id\":%s}}}", id);
