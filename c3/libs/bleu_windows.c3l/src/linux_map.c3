<*
 Mapping the compositor's model (bleu::compositor) onto the windows model.

 Only the Linux backend knows the compositor types, so the mapping lives in a
 file gated to Linux. It is pure: it reads a model and fills a state.

 What each compositor reports is recorded in `Window.reported`. The compositor
 model says `fullscreen`, `maximized` and `urgent` only when the compositor
 sends them (`Maybe`), and it has no minimized or pinned state at all; those
 bits stay clear in `reported` and the corresponding flags stay false.
*>
module bleu::windows::linux_map @feat(LINUX);
import std::collections::maybe, bleu::windows, bleu::compositor;

<*
 Fill `state` from `model`. Connection and status are left to the caller, and
 window titles are reported on every compositor this backend talks to.

 @param allocator : "Allocator for the strings and arrays of `state` (the snapshot's arena)"
*>
fn void fill_state(windows::State* state, compositor::Model* model, Allocator allocator)
{
	state.connection = windows::Connection.CONNECTED;
	state.status = "";
	state.titles_available = true;
	state.focused_window_id = "";
	state.windows = alloc::new_array(allocator, windows::Window, model.windows.len);
	foreach (i, window : model.windows)
	{
		state.windows[i] = window_of(window, allocator);
		if (window.focused) state.focused_window_id = window.id.copy(allocator);
	}
	state.workspaces = alloc::new_array(allocator, windows::Workspace, model.workspaces.len);
	foreach (i, workspace : model.workspaces)
	{
		state.workspaces[i] = workspace_of(workspace, state.windows, allocator);
	}
	state.outputs = alloc::new_array(allocator, windows::Output, model.outputs.len);
	foreach (i, output : model.outputs)
	{
		state.outputs[i] = output_of(output, allocator);
	}
}

fn windows::Window window_of(compositor::Window source, Allocator allocator) @private
{
	windows::WindowFlags flags;
	flags.focused = source.focused;
	flags.floating = source.floating;
	flags.fullscreen = source.fullscreen.has_value && source.fullscreen.value;
	flags.maximized = source.maximized.has_value && source.maximized.value;
	flags.urgent = source.urgent.has_value && source.urgent.value;
	windows::WindowFlags reported;
	reported.focused = true;
	reported.floating = true;
	reported.fullscreen = source.fullscreen.has_value;
	reported.maximized = source.maximized.has_value;
	reported.urgent = source.urgent.has_value;
	return {
		.id = source.id.copy(allocator),
		.title = source.title.copy(allocator),
		.app_id = source.app_id.copy(allocator),
		.icon_hint = source.app_id.copy(allocator),
		.pid = source.pid,
		.workspace_id = source.workspace_id.copy(allocator),
		.output_id = source.output.copy(allocator),
		.geometry = rect_of(source.geometry),
		.flags = flags,
		.reported = reported,
	};
}

// Every workspace counts the listed windows that name it.
fn windows::Workspace workspace_of(compositor::Workspace source, windows::Window[] listed, Allocator allocator) @private
{
	int count = 0;
	foreach (window : listed)
	{
		if (window.workspace_id == source.id) count++;
	}
	return {
		.id = source.id.copy(allocator),
		.name = source.name.copy(allocator),
		.output_id = source.output.copy(allocator),
		.active = source.focused,
		.visible = source.active,
		.window_count = count,
		.urgent = source.urgent,
	};
}

fn windows::Output output_of(compositor::Output source, Allocator allocator) @private
{
	return {
		.id = source.name.copy(allocator),
		.name = source.name.copy(allocator),
		.focused = source.focused,
		.active_workspace_id = source.active_workspace.copy(allocator),
		.geometry = rect_of(source.geometry),
	};
}

fn Maybe{windows::Rect} rect_of(Maybe{compositor::Rect} source) @private
{
	if (!source.has_value) return { };
	compositor::Rect r = source.value;
	windows::Rect rect = { .x = r.x, .y = r.y, .width = r.width, .height = r.height };
	return maybe::value(rect);
}