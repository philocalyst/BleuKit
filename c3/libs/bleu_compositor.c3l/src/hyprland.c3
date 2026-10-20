<*
 Hyprland's IPC, pure part: the JSON replies of the command socket become a
 `compositor::Model`, and the `EVENT>>DATA` lines of the event socket become
 `RawEvent`s that `apply` folds into a retained model.

 Sources: the Hyprland IPC wiki (https://wiki.hypr.land/IPC/: socket names, the
 `EVENT>>DATA` line form and the event list) and hyprland-rs 0.4.0-beta.2
 (`src/data/regular.rs`: object members, `FullscreenMode`; `src/event_listener/shared.rs`:
 the field count of each event, applied as `splitn`). Socket I/O is in
 `hyprland_io.c3`.
*>
module bleu::compositor::hyprland;
import std::collections::object, std::collections::maybe, bleu::error, bleu::compositor, bleu::compositor::backend, bleu::compositor::wire;

<*
 The replies `build` reads, one per command. Every tree is in temporary memory.
*>
struct Replies
{
	Object* clients;    // `j/clients`: array of window objects
	Object* active;     // `j/activewindow`: one window object, or an empty object when nothing is focused
	Object* workspaces; // `j/workspaces`: array of workspace objects
	Object* monitors;   // `j/monitors`: array of monitor objects
	Object* devices;    // `j/devices`: object with a `keyboards` array
}

// Bits of a client's `fullscreen` member (hyprland-rs `FullscreenMode`): 1 is
// maximized, 2 is fullscreen, 3 is both.
const long FULLSCREEN_MAXIMIZED_BIT = 1;
const long FULLSCREEN_BIT = 2;

<*
 Build the model from one set of replies.

 @param allocator : "Long-lived allocator for the model (not tmem)"
 @return? error::PROTOCOL : "A list reply is not an array"
*>
fn compositor::Model? build(Allocator allocator, Replies replies)
{
	if (!replies.clients.is_array() || !replies.workspaces.is_array() || !replies.monitors.is_array())
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "hyprland: a list reply is not an array")~;
	}
	String focused = wire::peek(replies.active, "address");
	return {
		.kind = compositor::Kind.HYPRLAND,
		.workspaces = workspaces(replies, allocator),
		.windows = windows(replies, focused, allocator),
		.outputs = outputs(replies.monitors, allocator),
		.layouts = layouts(replies.devices, allocator),
	};
}

fn compositor::Workspace[] workspaces(Replies replies, Allocator allocator) @private
{
	sz count = wire::length(replies.workspaces);
	compositor::Workspace[] out = alloc::new_array(allocator, compositor::Workspace, count);
	for (sz i = 0; i < count; i++)
	{
		Object* workspace = wire::item(replies.workspaces, i);
		long id = wire::integer_member(workspace, "id");
		String output = wire::text_member(workspace, "monitor", allocator);
		bool active = shows_on_monitor(replies.monitors, id);
		out[i] = {
			.id = id_text(id, allocator),
			.name = wire::text_member(workspace, "name", allocator),
			.output = output,
			.active = active,
			.focused = active && monitor_focused(replies.monitors, output),
			.urgent = {},
		};
	}
	return out;
}

fn compositor::Window[] windows(Replies replies, String focused, Allocator allocator) @private
{
	sz count = wire::length(replies.clients);
	compositor::Window[] out = alloc::new_array(allocator, compositor::Window, count);
	for (sz i = 0; i < count; i++)
	{
		Object* client = wire::item(replies.clients, i);
		long mode = wire::integer_member(client, "fullscreen");
		String address = wire::text_member(client, "address", allocator);
		out[i] = {
			.id = address,
			.title = wire::text_member(client, "title", allocator),
			.app_id = wire::text_member(client, "class", allocator),
			.pid = pid_of(client),
			.workspace_id = id_member_text(client, "workspace", allocator),
			.output = monitor_name(replies.monitors, wire::integer_member(client, "monitor", -1), allocator),
			.focused = focused.len > 0 && address == focused,
			.floating = wire::flag_member(client, "floating"),
			.fullscreen = { .value = (mode & FULLSCREEN_BIT) != 0, .has_value = true },
			.maximized = { .value = (mode & FULLSCREEN_MAXIMIZED_BIT) != 0, .has_value = true },
			.urgent = wire::optional_flag(client, "urgent"),
			.geometry = client_geometry(client),
		};
	}
	return out;
}

fn compositor::Output[] outputs(Object* monitors, Allocator allocator) @private
{
	sz count = wire::length(monitors);
	compositor::Output[] out = alloc::new_array(allocator, compositor::Output, count);
	for (sz i = 0; i < count; i++)
	{
		Object* monitor = wire::item(monitors, i);
		out[i] = {
			.name = wire::text_member(monitor, "name", allocator),
			.geometry = monitor_geometry(monitor),
			.scale = wire::number_member(monitor, "scale"),
			.active_workspace = id_member_text(monitor, "activeWorkspace", allocator),
			.focused = wire::flag_member(monitor, "focused"),
		};
	}
	return out;
}

// The main keyboard, or the first keyboard when none is marked main. Hyprland
// reports the active layout's name only, so `names` stays empty.
fn compositor::KeyboardLayouts layouts(Object* devices, Allocator allocator) @private
{
	Object*? keyboards = wire::member(devices, "keyboards");
	if (catch err = keyboards) return {};
	if (!keyboards.is_array()) return {};
	Object* first = null;
	for (sz i = 0; i < wire::length(keyboards); i++)
	{
		Object* keyboard = wire::item(keyboards, i);
		if (wire::flag_member(keyboard, "main")) return keyboard_layouts(keyboard, allocator);
		if (first == null) first = keyboard;
	}
	if (first == null) return {};
	return keyboard_layouts(first, allocator);
}

fn compositor::KeyboardLayouts keyboard_layouts(Object* keyboard, Allocator allocator) @private
{
	return {
		.names = {},
		.current = {},
		.current_name = wire::text_member(keyboard, "active_keymap", allocator),
	};
}

// A window object's `pid`: Hyprland writes 0 or -1 for a window with no process.
fn Maybe{int} pid_of(Object* client) @private
{
	Maybe{long} pid = wire::optional_integer(client, "pid");
	if (!pid.has_value || pid.value <= 0) return {};
	return { .value = (int)pid.value, .has_value = true };
}

// The `id` of a nested object such as `workspace` or `activeWorkspace`, as text.
fn String id_member_text(Object* obj, String key, Allocator allocator) @private
{
	Maybe{long} id = nested_id(obj, key);
	if (!id.has_value) return "";
	return id_text(id.value, allocator);
}

fn Maybe{long} nested_id(Object* obj, String key) @private
{
	Object*? nested = wire::member(obj, key);
	if (catch err = nested) return {};
	return wire::optional_integer(nested, "id");
}

fn String id_text(long id, Allocator allocator) @private => string::tformat("%d", id).copy(allocator);

fn bool shows_on_monitor(Object* monitors, long workspace_id) @private
{
	for (sz i = 0; i < wire::length(monitors); i++)
	{
		Maybe{long} shown = nested_id(wire::item(monitors, i), "activeWorkspace");
		if (shown.has_value && shown.value == workspace_id) return true;
	}
	return false;
}

fn bool monitor_focused(Object* monitors, String name) @private
{
	for (sz i = 0; i < wire::length(monitors); i++)
	{
		Object* monitor = wire::item(monitors, i);
		if (wire::flag_member(monitor, "focused") && (wire::peek(monitor, "name")) == name) return true;
	}
	return false;
}

fn String monitor_name(Object* monitors, long monitor_id, Allocator allocator) @private
{
	for (sz i = 0; i < wire::length(monitors); i++)
	{
		Object* monitor = wire::item(monitors, i);
		if (wire::integer_member(monitor, "id", -1) == monitor_id) return wire::text_member(monitor, "name", allocator);
	}
	return "";
}

fn Maybe{Rect} monitor_geometry(Object* monitor) @private
{
	Rect rect = {
		.x = (int)wire::integer_member(monitor, "x"),
		.y = (int)wire::integer_member(monitor, "y"),
		.width = (int)wire::integer_member(monitor, "width"),
		.height = (int)wire::integer_member(monitor, "height"),
	};
	return { .value = rect, .has_value = true };
}

// A client has `at: [x, y]` and `size: [width, height]`.
fn Maybe{Rect} client_geometry(Object* client) @private
{
	Object*? at = wire::member(client, "at");
	if (catch err = at) return {};
	Object*? size = wire::member(client, "size");
	if (catch err = size) return {};
	Rect rect = {
		.x = (int)wire::integer_element(at, 0),
		.y = (int)wire::integer_element(at, 1),
		.width = (int)wire::integer_element(size, 0),
		.height = (int)wire::integer_element(size, 1),
	};
	return { .value = rect, .has_value = true };
}

<*
 Split an event line `EVENT>>DATA` at its first `>>`.

 @return "The event name and its data, as text inside the line"
 @return? error::PROTOCOL : "The line has no `>>` separator"
*>
fn backend::RawEvent? parse_event(String line)
{
	sz? found = line.index_of(">>");
	if (catch err = found) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "hyprland event has no '>>'")~;
	sz separator = found;
	return { .name = line[0 : separator], .payload = line[separator + 2 : line.len - (separator + 2)] };
}

<*
 Fold one Hyprland event into `model`. Events that only change focus, title,
 floating or urgency, and the opening and closing of windows, are applied in place.
 Events that change workspaces, outputs or the config request a snapshot.
 Events this model does not hold (groups, layers, pins, submaps, ...) change nothing.
 A payload that does not have the documented fields requests a snapshot too.

 @param allocator : "Allocator for new arrays and strings in `model` (not tmem)"
*>
fn backend::Refresh apply(compositor::Model* model, Allocator allocator, backend::RawEvent event)
{
	switch
	{
		case event.name == "activewindowv2": return focus_changed(model, event.payload);
		case event.name == "openwindow": return window_opened(model, allocator, event.payload);
		case event.name == "closewindow": return window_closed(model, allocator, event.payload);
		case event.name == "windowtitlev2": return window_titled(model, allocator, event.payload);
		case event.name == "fullscreen": return fullscreen_changed(model, event.payload);
		case event.name == "changefloatingmode": return floating_changed(model, event.payload);
		case event.name == "urgent": return urgent_set(model, event.payload);
		case event.name == "movewindowv2": return window_moved(model, event.payload);
		case event.name == "activelayout": return layout_changed(model, allocator, event.payload);
		case is_model_wide(event.name): return REFRESH_NEEDED;
		default: return NONE;
	}
}

// Events whose effect spans workspaces, outputs or the configuration.
fn bool is_model_wide(String name) @private
{
	return name == "workspace" || name == "workspacev2" || name == "createworkspace"
		|| name == "createworkspacev2" || name == "destroyworkspace" || name == "destroyworkspacev2"
		|| name == "moveworkspace" || name == "moveworkspacev2" || name == "renameworkspace"
		|| name == "focusedmon" || name == "focusedmonv2" || name == "monitoradded"
		|| name == "monitoraddedv2" || name == "monitorremoved" || name == "monitorremovedv2"
		|| name == "activespecial" || name == "activespecialv2" || name == "configreloaded";
}

// `ADDRESS` (empty when nothing is focused). Focus may move inside the focused
// workspace only; any other move asks for a snapshot.
fn backend::Refresh focus_changed(compositor::Model* model, String address) @private
{
	if (address.len == 0)
	{
		clear_focus(model);
		return UPDATED;
	}
	sz target = window_index(model, address);
	if (target < 0) return REFRESH_NEEDED;
	compositor::Window* window = &model.windows[target];
	if (!workspace_is_focused(model, window.workspace_id)) return REFRESH_NEEDED;
	clear_focus(model);
	window.focused = true;
	return UPDATED;
}

// `ADDRESS,WORKSPACENAME,CLASS,TITLE`. Opened windows have no pid or geometry
// until the next snapshot.
fn backend::Refresh window_opened(compositor::Model* model, Allocator allocator, String payload) @private
{
	String address = wire::nth_field(payload, 0, 4) ?? "";
	String workspace_name = wire::nth_field(payload, 1, 4) ?? "";
	String app_class = wire::nth_field(payload, 2, 4) ?? "";
	String title = wire::nth_field(payload, 3, 4) ?? "";
	if (address.len == 0 || workspace_name.len == 0) return REFRESH_NEEDED;
	sz workspace = workspace_index_by_name(model, workspace_name);
	if (workspace < 0 || window_index(model, address) >= 0) return REFRESH_NEEDED;
	compositor::Window opened = {
		.id = address.copy(allocator),
		.title = title.copy(allocator),
		.app_id = app_class.copy(allocator),
		.workspace_id = model.workspaces[workspace].id,
		.output = model.workspaces[workspace].output,
	};
	sz count = model.windows.len;
	compositor::Window[] windows = alloc::new_array(allocator, compositor::Window, count + 1);
	for (sz i = 0; i < count; i++) windows[i] = model.windows[i];
	windows[count] = opened;
	model.windows = windows;
	return UPDATED;
}

// `ADDRESS`.
fn backend::Refresh window_closed(compositor::Model* model, Allocator allocator, String payload) @private
{
	String address = wire::nth_field(payload, 0, 1) ?? "";
	sz target = window_index(model, address);
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

// `ADDRESS,TITLE`.
fn backend::Refresh window_titled(compositor::Model* model, Allocator allocator, String payload) @private
{
	String address = wire::nth_field(payload, 0, 2) ?? "";
	String title = wire::nth_field(payload, 1, 2) ?? "";
	sz target = window_index(model, address);
	if (target < 0) return REFRESH_NEEDED;
	model.windows[target].title = title.copy(allocator);
	return UPDATED;
}

// `0` or `1`, for the focused window.
fn backend::Refresh fullscreen_changed(compositor::Model* model, String payload) @private
{
	sz target = focused_index(model);
	if (target < 0) return REFRESH_NEEDED;
	model.windows[target].fullscreen = { .value = payload == "1", .has_value = true };
	return UPDATED;
}

// `ADDRESS,FLOATING` where FLOATING is `0` or `1`.
fn backend::Refresh floating_changed(compositor::Model* model, String payload) @private
{
	String address = wire::nth_field(payload, 0, 2) ?? "";
	String floating = wire::nth_field(payload, 1, 2) ?? "";
	sz target = window_index(model, address);
	if (target < 0) return REFRESH_NEEDED;
	model.windows[target].floating = floating == "1";
	return UPDATED;
}

// `ADDRESS`.
fn backend::Refresh urgent_set(compositor::Model* model, String payload) @private
{
	String address = wire::nth_field(payload, 0, 1) ?? "";
	sz target = window_index(model, address);
	if (target < 0) return REFRESH_NEEDED;
	model.windows[target].urgent = { .value = true, .has_value = true };
	return UPDATED;
}

// `ADDRESS,WORKSPACEID,WORKSPACENAME`.
fn backend::Refresh window_moved(compositor::Model* model, String payload) @private
{
	String address = wire::nth_field(payload, 0, 3) ?? "";
	String workspace_id = wire::nth_field(payload, 1, 3) ?? "";
	sz target = window_index(model, address);
	sz workspace = workspace_index(model, workspace_id);
	if (target < 0 || workspace < 0) return REFRESH_NEEDED;
	model.windows[target].workspace_id = model.workspaces[workspace].id;
	model.windows[target].output = model.workspaces[workspace].output;
	return UPDATED;
}

// `KEYBOARD,LAYOUT`: the layout name of the keyboard that changed.
fn backend::Refresh layout_changed(compositor::Model* model, Allocator allocator, String payload) @private
{
	String layout = wire::nth_field(payload, 1, 2) ?? "";
	if (layout.len == 0) return REFRESH_NEEDED;
	model.layouts.current_name = layout.copy(allocator);
	return UPDATED;
}

fn sz window_index(compositor::Model* model, String address) @private
{
	for (sz i = 0; i < model.windows.len; i++)
	{
		if (model.windows[i].id == address) return i;
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

fn sz workspace_index_by_name(compositor::Model* model, String name) @private
{
	for (sz i = 0; i < model.workspaces.len; i++)
	{
		if (model.workspaces[i].name == name) return i;
	}
	return -1;
}

fn sz focused_index(compositor::Model* model) @private
{
	for (sz i = 0; i < model.windows.len; i++)
	{
		if (model.windows[i].focused) return i;
	}
	return -1;
}

fn bool workspace_is_focused(compositor::Model* model, String id) @private
{
	sz index = workspace_index(model, id);
	return index >= 0 && model.workspaces[index].focused;
}

fn void clear_focus(compositor::Model* model) @private
{
	for (sz i = 0; i < model.windows.len; i++) model.windows[i].focused = false;
}
