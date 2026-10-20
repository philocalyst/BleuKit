<*
 Compositor-neutral window-manager model: the workspaces, windows, outputs and
 keyboard layouts of the running compositor, as plain data.

 Every `String` is owned by the arena of the snapshot that holds the model, so a
 model can be copied, published and released as one unit (see `Model.clone`).

 Identifiers are the compositor's own ids written as text:
 * Hyprland: window addresses such as "0x55d1c0a4e2b0" and workspace ids "1", "-98".
 * niri: numeric ids as decimal text.
 * sway and i3: container ids as decimal text for windows, and the workspace
   *name* for workspaces (sway addresses workspaces by name in commands).

 Unknown is not zero. A value a compositor does not report is a `Maybe{T}` with
 `has_value` false, and a text field is "" when unknown.
*>
module bleu::compositor;
import std::collections::maybe;

<*
 Which compositor or window manager is running.
 `RIVER` and `DWL` are recognised from the environment only: this library has
 no IPC client for them, so `open` refuses them.
*>
enum Kind : char
{
	NONE,
	HYPRLAND,
	SWAY,
	I3,
	NIRI,
	RIVER,
	DWL,
}

<* A rectangle in global logical pixels. *>
struct Rect
{
	int x;
	int y;
	int width;
	int height;
}

<* One workspace. *>
struct Workspace
{
	String id;     // Hyprland and niri: numeric id. sway and i3: the workspace name.
	String name;   // Display name, "" when the workspace is unnamed.
	String output; // Name of the output it is on, "" when unknown.
	bool active;   // Currently shown on its output.
	bool focused;  // Holds keyboard focus.
	bool urgent;   // Has a window asking for attention.
}

<*
 One toplevel window.

 `geometry` is absent on niri, which reports tile offsets inside the workspace
 view but no absolute position. `fullscreen`, `maximized` and `urgent` are absent
 where the compositor does not report them (see the backend README for each).
*>
struct Window
{
	String id;             // Compositor id, see the module comment.
	String title;
	String app_id;         // Wayland app id, Hyprland class, sway app_id or X11 class.
	Maybe{int} pid;
	String workspace_id;   // "" when unknown.
	String output;         // "" when unknown.
	bool focused;
	bool floating;
	Maybe{bool} fullscreen;
	Maybe{bool} maximized;
	Maybe{bool} urgent;
	Maybe{Rect} geometry;
}

<* One enabled output (monitor). *>
struct Output
{
	String name;
	Maybe{Rect} geometry;
	Maybe{double} scale;
	String active_workspace; // Id (as in `Workspace.id`) of the workspace shown here, "" when unknown.
	bool focused;
}

<*
 The keyboard layouts of the main keyboard.

 `names` is empty when the compositor reports only the active layout's name
 (Hyprland). `current` is the index into `names`, absent when unknown.
*>
struct KeyboardLayouts
{
	String[] names;
	Maybe{int} current;
	String current_name;
}

<* Everything a shell shows about the compositor at one instant. *>
struct Model
{
	Kind kind;
	Workspace[] workspaces;
	Window[] windows;
	Output[] outputs;
	KeyboardLayouts layouts;
}

<*
 Deep copy of `self` into `allocator`. The copy shares no memory with `self`, so
 a retained model can keep changing while earlier copies are published.

 @param allocator : "Long-lived allocator for the copy (not tmem)"
 @return "The copy; allocation failure aborts"
*>
fn Model Model.clone(&self, Allocator allocator)
{
	return {
		.kind = self.kind,
		.workspaces = clone_workspaces(self.workspaces, allocator),
		.windows = clone_windows(self.windows, allocator),
		.outputs = clone_outputs(self.outputs, allocator),
		.layouts = clone_layouts(self.layouts, allocator),
	};
}

fn Workspace[] clone_workspaces(Workspace[] source, Allocator allocator) @private
{
	Workspace[] out = alloc::new_array(allocator, Workspace, source.len);
	foreach (i, item : source)
	{
		out[i] = {
			.id = item.id.copy(allocator),
			.name = item.name.copy(allocator),
			.output = item.output.copy(allocator),
			.active = item.active,
			.focused = item.focused,
			.urgent = item.urgent,
		};
	}
	return out;
}

fn Window[] clone_windows(Window[] source, Allocator allocator) @private
{
	Window[] out = alloc::new_array(allocator, Window, source.len);
	foreach (i, item : source)
	{
		out[i] = {
			.id = item.id.copy(allocator),
			.title = item.title.copy(allocator),
			.app_id = item.app_id.copy(allocator),
			.pid = item.pid,
			.workspace_id = item.workspace_id.copy(allocator),
			.output = item.output.copy(allocator),
			.focused = item.focused,
			.floating = item.floating,
			.fullscreen = item.fullscreen,
			.maximized = item.maximized,
			.urgent = item.urgent,
			.geometry = item.geometry,
		};
	}
	return out;
}

fn Output[] clone_outputs(Output[] source, Allocator allocator) @private
{
	Output[] out = alloc::new_array(allocator, Output, source.len);
	foreach (i, item : source)
	{
		out[i] = {
			.name = item.name.copy(allocator),
			.geometry = item.geometry,
			.scale = item.scale,
			.active_workspace = item.active_workspace.copy(allocator),
			.focused = item.focused,
		};
	}
	return out;
}

fn KeyboardLayouts clone_layouts(KeyboardLayouts source, Allocator allocator) @private
{
	String[] names = alloc::new_array(allocator, String, source.names.len);
	foreach (i, name : source.names) names[i] = name.copy(allocator);
	return {
		.names = names,
		.current = source.current,
		.current_name = source.current_name.copy(allocator),
	};
}
