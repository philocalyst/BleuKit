<*
 sway and i3, pure part: the replies of GET_WORKSPACES, GET_OUTPUTS, GET_TREE and
 GET_INPUTS become a `compositor::Model`, and the event payloads of `window`,
 `workspace` and `input` events are folded into a retained model.

 The tree is walked to a flat window list. A window is a leaf container that
 holds a view (app_id, X11 window or window properties). The focus path is
 followed from the root through each node's `focus` list, which gives the
 focused window and the focused workspace.

 Sources: the i3 IPC document (https://i3wm.org/docs/ipc.html: reply and event
 member names) as implemented by sway: `include/sway/ipc-json.h` and
 `sway/ipc-server.c` for the node layout, swayipc-types 2.0.3 `reply.rs` for the
 field types (`Node`, `Workspace`, `Output`, `Input`, `WindowChange`,
 `WorkspaceChange`, `InputChange`).
*>
module bleu::compositor::sway @feat(POSIX);
import std::collections::object, std::collections::maybe, bleu::error, bleu::compositor, bleu::compositor::backend, bleu::compositor::wire;

<*
 The replies `build` reads. `inputs` is null on i3, which has no GET_INPUTS.
 Every tree is in temporary memory.
*>
struct Replies
{
	Object* workspaces; // GET_WORKSPACES: array
	Object* outputs; // GET_OUTPUTS: array
	Object* tree; // GET_TREE: the root node object
	Object* inputs; // GET_INPUTS: array, or null
}

// Deepest container nesting accepted. Sway's own trees are a few levels deep.
const usz MAX_TREE_DEPTH = 64;

// The two member names under which a node holds its children.
const String[2] CHILD_KEYS = { "nodes", "floating_nodes" };

// The focused window at the end of the focus path, if the path ends at one.
struct Focus
{
	bool has_window;
	long window_id;
}

<*
 Build the model from one set of replies.

 @param allocator : "Long-lived allocator for the model (not tmem)"
 @require kind == compositor::Kind.SWAY || kind == compositor::Kind.I3 : "Only sway and i3 use this reader"
 @return? error::PROTOCOL : "A reply is not in the documented shape, or the tree is nested too deep"
*>
fn compositor::Model? build(Allocator allocator, compositor::Kind kind, Replies replies)
{
	if (!replies.workspaces.is_array() || !replies.outputs.is_array() || !replies.tree.is_map())
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "sway: a reply has the wrong shape")~;
	}
	Focus focus                  = focus_path(replies.tree);
	sz window_count              = count_windows(replies.tree, 0);
	compositor::Window[] windows = alloc::new_array(allocator, compositor::Window, window_count);
	sz filled                    = 0;
	collect_windows(replies.tree, "", "", &focus, windows, &filled, allocator, 0)!;
	return {
		.kind = kind,
		.workspaces = workspaces(replies.workspaces, allocator),
		.windows = windows[0:filled],
		.outputs = outputs(replies.outputs, allocator),
		.layouts = layouts(replies.inputs, allocator),
	};
}

// Follow `focus[0]` from the root through each node. The path ends at the focused leaf;
// when that leaf is a window, it is the focused window.
fn Focus focus_path(Object* root) @private
{
	Focus focus  = { };
	Object* node = root;
	for (usz depth = 0; depth < MAX_TREE_DEPTH; depth++)
	{
		Object*? focus_list = wire::member(node, "focus");
		if (catch err = focus_list) return focus;
		if (!focus_list.is_array() || wire::length(focus_list) == 0) return focus;
		long next     = wire::integer_element(focus_list, 0, -1);
		Object* child = child_with_id(node, next);
		if (child == null) return focus;
		if (is_window(child))
		{
			focus.has_window = true;
			focus.window_id = wire::integer_member(child, "id");
		}
		node = child;
	}
	return focus;
}

// The child of `node` (in `nodes` or `floating_nodes`) whose `id` is `id`.
fn Object* child_with_id(Object* node, long id) @private
{
	foreach (key : CHILD_KEYS)
	{
		Object*? children = wire::member(node, key);
		if (catch err = children) continue;
		if (!children.is_array()) continue;
		for (sz i = 0; i < wire::length(children); i++)
		{
			Object* child = wire::item(children, i);
			if (wire::integer_member(child, "id", -1) == id) return child;
		}
	}
	return null;
}

// A leaf container that holds a view. Containers with children are never windows.
fn bool is_window(Object* node) @private
{
	String type = wire::peek(node, "type");
	if (type != "con" && type != "floating_con") return false;
	if (has_children(node)) return false;
	return wire::present(node, "app_id") || wire::present(node, "window") || wire::present(node, "window_properties");
}

fn bool has_children(Object* node) @private
{
	foreach (key : CHILD_KEYS)
	{
		Object*? children = wire::member(node, key);
		if (catch err = children) continue;
		if (children.is_array() && wire::length(children) > 0) return true;
	}
	return false;
}

fn sz count_windows(Object* node, usz depth) @private
{
	if (depth > MAX_TREE_DEPTH) return 0;
	if (is_window(node)) return 1;
	sz total = 0;
	foreach (key : CHILD_KEYS)
	{
		Object*? children = wire::member(node, key);
		if (catch err = children) continue;
		if (!children.is_array()) continue;
		for (sz i = 0; i < wire::length(children); i++) total += count_windows(wire::item(children, i), depth + 1);
	}
	return total;
}

// Fill `windows[*filled..]` with the windows under `node`. `workspace` and `output`
// are the names of the enclosing workspace and output.
fn void? collect_windows(
	Object* node,
	String workspace,
	String output,
	Focus* focus,
	compositor::Window[] windows,
	sz* filled,
	Allocator allocator,
	usz depth
) @private
{
	if (depth > MAX_TREE_DEPTH) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"sway tree is nested deeper than %d",
		MAX_TREE_DEPTH
	)~;
	String type           = wire::peek(node, "type");
	String node_workspace = workspace;
	String node_output    = output;
	if (type == "output") node_output = wire::peek(node, "name");
	if (type == "workspace") node_workspace = wire::peek(node, "name");
	if (is_window(node))
	{
		windows[*filled] = window_of(node, node_workspace, node_output, focus, allocator);
		*filled += 1;
		return;
	}
	foreach (key : CHILD_KEYS)
	{
		Object*? children = wire::member(node, key);
		if (catch err = children) continue;
		if (!children.is_array()) continue;
		for (sz i = 0; i < wire::length(children); i++)
		{
			collect_windows(
				wire::item(children, i),
				node_workspace,
				node_output,
				focus,
				windows,
				filled,
				allocator,
				depth + 1
			)!;
		}
	}
}

fn compositor::Window window_of(
	Object* node,
	String workspace,
	String output,
	Focus* focus,
	Allocator allocator
) @private
{
	String app_id = wire::text_member(node, "app_id", allocator);
	if (app_id.len == 0) app_id = window_class(node, allocator);
	long id     = wire::integer_member(node, "id");
	String type = wire::peek(node, "type");
	return {
		.id = id_text(id, allocator),
		.title = wire::text_member(node, "name", allocator),
		.app_id = app_id,
		.pid = pid_of(node),
		.workspace_id = workspace.copy(allocator),
		.output = output.copy(allocator),
		.focused = focus.has_window && focus.window_id == id,
		.floating = type == "floating_con" || wire::present(node, "floating"),
		.fullscreen = { .value = wire::integer_member(node, "fullscreen_mode") > 0, .has_value = true },
		.maximized = { },
		.urgent = wire::optional_flag(node, "urgent"),
		.geometry = rect_member(node, "rect"),
	};
}

// The X11 class of a window, from `window_properties` when there is no app_id.
fn String window_class(Object* node, Allocator allocator) @private
{
	Object*? properties = wire::member(node, "window_properties");
	if (catch err = properties) return "";
	return wire::text_member(properties, "class", allocator);
}

fn Maybe{int} pid_of(Object* node) @private
{
	Maybe{long} pid = wire::optional_integer(node, "pid");
	if (!pid.has_value || pid.value <= 0) return { };
	return { .value = (int)pid.value, .has_value = true };
}

fn String id_text(long id, Allocator allocator) @private => string::tformat("%d", id).copy(allocator);

// A rectangle member `{x, y, width, height}`.
fn Maybe{Rect} rect_member(Object* obj, String key) @private
{
	Object*? rect = wire::member(obj, key);
	if (catch err = rect) return { };
	Rect value = {
		.x = (int)wire::integer_member(rect, "x"),
		.y = (int)wire::integer_member(rect, "y"),
		.width = (int)wire::integer_member(rect, "width"),
		.height = (int)wire::integer_member(rect, "height"),
	};
	return { .value = value, .has_value = true };
}

fn compositor::Workspace[] workspaces(Object* list, Allocator allocator) @private
{
	sz count                    = wire::length(list);
	compositor::Workspace[] out = alloc::new_array(allocator, compositor::Workspace, count);
	for (sz i = 0; i < count; i++)
	{
		Object* workspace = wire::item(list, i);
		out[i] = {
			.id = wire::text_member(workspace, "name", allocator),
			.name = wire::text_member(workspace, "name", allocator),
			.output = wire::text_member(workspace, "output", allocator),
			.active = wire::flag_member(workspace, "visible"),
			.focused = wire::flag_member(workspace, "focused"),
			.urgent = wire::optional_flag(workspace, "urgent"),
		};
	}
	return out;
}

// Active outputs only: sway lists disabled outputs too, which a shell does not show.
fn compositor::Output[] outputs(Object* list, Allocator allocator) @private
{
	sz count = 0;
	for (sz i = 0; i < wire::length(list); i++) count += wire::flag_member(wire::item(list, i), "active") ? 1 : 0;
	compositor::Output[] out = alloc::new_array(allocator, compositor::Output, count);
	sz filled                = 0;
	for (sz i = 0; i < wire::length(list); i++)
	{
		Object* output = wire::item(list, i);
		if (!wire::flag_member(output, "active")) continue;
		out[filled++] = {
			.name = wire::text_member(output, "name", allocator),
			.geometry = rect_member(output, "rect"),
			.scale = wire::number_member(output, "scale"),
			.active_workspace = wire::text_member(output, "current_workspace", allocator),
			.focused = wire::flag_member(output, "focused"),
		};
	}
	return out;
}

// The first keyboard that has layouts. i3 passes null and gets no layouts.
fn compositor::KeyboardLayouts layouts(Object* inputs, Allocator allocator) @private
{
	if (inputs == null || !inputs.is_array()) return { };
	for (sz i = 0; i < wire::length(inputs); i++)
	{
		Object* input = wire::item(inputs, i);
		if ((wire::peek(input, "type")) != "keyboard") continue;
		Object*? names = wire::member(input, "xkb_layout_names");
		if (catch err = names) continue;
		if (!names.is_array() || wire::length(names) == 0) continue;
		return keyboard_layouts(input, names, allocator);
	}
	return { };
}

fn Maybe{int} optional_index(Object* input) @private
{
	Maybe{long} index = wire::optional_integer(input, "xkb_active_layout_index");
	if (!index.has_value) return { };
	return { .value = (int)index.value, .has_value = true };
}

fn compositor::KeyboardLayouts keyboard_layouts(Object* input, Object* names, Allocator allocator) @private
{
	String[] copies = alloc::new_array(allocator, String, wire::length(names));
	for (sz i = 0; i < wire::length(names); i++) copies[i] = wire::text_element(names, i, allocator);
	return {
		.names = copies,
		.current = optional_index(input),
		.current_name = wire::text_member(input, "xkb_active_layout_name", allocator),
	};
}

<*
 Fold one sway event into `model`. `window` (focus, title, urgency, floating,
 fullscreen, close), `workspace` (focus, urgency) and `input` (layout changes)
 are applied in place; adding or moving windows and workspace lifecycle events
 request a snapshot. A payload that cannot be read requests a snapshot.

 @param allocator : "Allocator for new arrays and strings in `model` (not tmem)"
*>
fn backend::Refresh apply(compositor::Model* model, Allocator allocator, backend::RawEvent event)
{
	@pool()
	{
		Object*? root = wire::parse_document(event.payload, "sway event");
		if (catch err = root) return REFRESH_NEEDED;
		switch
		{
			case event.name == "window": return window_event(model, allocator, root);
			case event.name == "workspace": return workspace_event(model, allocator, root);
			case event.name == "input": return input_event(model, allocator, root);
			case event.name == "output": return REFRESH_NEEDED;
			default: return NONE;
		}
	};
}

fn backend::Refresh window_event(compositor::Model* model, Allocator allocator, Object* root) @private
{
	String change      = wire::peek(root, "change");
	Object*? container = wire::member(root, "container");
	if (catch err = container) return REFRESH_NEEDED;
	String id = id_text(wire::integer_member(container, "id"), allocator);
	sz target = window_index(model, id);
	switch
	{
		case change == "focus":
			if (target < 0) return REFRESH_NEEDED;
			clear_focus(model);
			model.windows[target].focused = true;
			return UPDATED;
		case change == "close":
			if (target < 0) return NONE;
			remove_window(model, allocator, target);
			return UPDATED;
		case change == "title":
			if (target < 0) return REFRESH_NEEDED;
			model.windows[target].title = wire::text_member(container, "name", allocator);
			return UPDATED;
		case change == "urgent":
			if (target < 0) return REFRESH_NEEDED;
			model.windows[target].urgent = wire::optional_flag(container, "urgent");
			return UPDATED;
		case change == "floating":
			if (target < 0) return REFRESH_NEEDED;
			model.windows[target].floating = (wire::peek(container, "type")) == "floating_con";
			return UPDATED;
		case change == "fullscreen_mode":
			if (target < 0) return REFRESH_NEEDED;
			model.windows[target].fullscreen = {
				.value = wire::integer_member(container, "fullscreen_mode") > 0,
				.has_value = true
			};
			return UPDATED;
		case change == "new" || change == "move":
			return REFRESH_NEEDED;
		default:
			return NONE;
	}
}

fn backend::Refresh workspace_event(compositor::Model* model, Allocator allocator, Object* root) @private
{
	String change    = wire::peek(root, "change");
	Object*? current = wire::member(root, "current");
	if (catch err = current) return REFRESH_NEEDED;
	String name = wire::text_member(current, "name", allocator);
	sz target   = workspace_index(model, name);
	switch
	{
		case change == "focus":
			if (target < 0) return REFRESH_NEEDED;
			String output = model.workspaces[target].output;
			for (sz i = 0; i < model.workspaces.len; i++)
			{
				compositor::Workspace* other = &model.workspaces[i];
				other.focused = other.name == name;
				if (other.output == output) other.active = other.name == name;
			}
			return UPDATED;
		case change == "urgent":
			if (target < 0) return REFRESH_NEEDED;
			model.workspaces[target].urgent = wire::optional_flag(current, "urgent");
			return UPDATED;
		case change == "init" || change == "empty" || change == "move" || change == "rename" || change == "reload":
			return REFRESH_NEEDED;
		default:
			return NONE;
	}
}

// Keyboard layout changes. The model holds one keyboard, the first with layouts;
// a layout change on any keyboard updates it, so the last one to change wins.
fn backend::Refresh input_event(compositor::Model* model, Allocator allocator, Object* root) @private
{
	String change  = wire::peek(root, "change");
	Object*? input = wire::member(root, "input");
	if (catch err = input) return REFRESH_NEEDED;
	if (change == "xkb_layout")
	{
		model.layouts.current = optional_index(input);
		model.layouts.current_name = wire::text_member(input, "xkb_active_layout_name", allocator);
		return UPDATED;
	}
	if (change == "added" || change == "removed" || change == "xkb_keymap") return REFRESH_NEEDED;
	return NONE;
}

fn sz window_index(compositor::Model* model, String id) @private
{
	for (sz i = 0; i < model.windows.len; i++)
	{
		if (model.windows[i].id == id) return i;
	}
	return -1;
}

fn sz workspace_index(compositor::Model* model, String name) @private
{
	for (sz i = 0; i < model.workspaces.len; i++)
	{
		if (model.workspaces[i].name == name) return i;
	}
	return -1;
}

fn void clear_focus(compositor::Model* model) @private
{
	for (sz i = 0; i < model.windows.len; i++) model.windows[i].focused = false;
}

fn void remove_window(compositor::Model* model, Allocator allocator, sz target) @private
{
	sz count                     = model.windows.len;
	compositor::Window[] windows = alloc::new_array(allocator, compositor::Window, count - 1);
	sz out                       = 0;
	for (sz i = 0; i < count; i++)
	{
		if (i == target) continue;
		windows[out++] = model.windows[i];
	}
	model.windows = windows;
}