module bleu::windows_linux_map_test @feat(LINUX);
import std::collections::maybe, bleu::windows, bleu::windows::linux_map, bleu::compositor;

// Builds a compositor model with one focused window on "1" and one floating window on "2".
fn void maps_windows_workspaces_and_outputs() @test
{
	compositor::Rect wide = { .x = 0, .y = 0, .width = 800, .height = 600 };
	compositor::Window[2] source_windows = {
		{
			.id = "0x1", .title = "~/src", .app_id = "foot", .pid = maybe::value(4242),
			.workspace_id = "1", .output = "DP-1", .focused = true, .floating = false,
			.fullscreen = maybe::value(false), .maximized = { }, .urgent = { },
			.geometry = maybe::value(wide),
		},
		{
			.id = "0x2", .title = "Calc", .app_id = "gnome-calculator", .pid = { },
			.workspace_id = "2", .output = "DP-1", .focused = false, .floating = true,
			.fullscreen = { }, .maximized = { }, .urgent = maybe::value(true), .geometry = { },
		},
	};
	compositor::Workspace[2] source_workspaces = {
		{ .id = "1", .name = "one", .output = "DP-1", .active = true, .focused = true, .urgent = maybe::value(false) },
		{ .id = "2", .name = "two", .output = "DP-1", .active = false, .focused = false, .urgent = { } },
	};
	compositor::Output[1] source_outputs = {
		{ .name = "DP-1", .geometry = { }, .scale = { }, .active_workspace = "1", .focused = true },
	};
	compositor::Model model = {
		.kind = compositor::Kind.HYPRLAND,
		.windows = source_windows[..],
		.workspaces = source_workspaces[..],
		.outputs = source_outputs[..],
	};
	windows::State state;
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	Allocator allocator = &arena;
	linux_map::fill_state(&state, &model, allocator);

	assert(state.connection == windows::CONNECTED);
	assert(state.focused_window_id == "0x1");
	assert(state.windows.len == 2);
	assert(state.windows[0].pid.value == 4242);
	assert(state.windows[0].icon_hint == "foot");
	assert(state.windows[0].geometry.value.width == 800);
	assert(state.windows[0].flags.focused);
	assert(!state.windows[0].flags.fullscreen);
	assert(state.windows[0].reported.fullscreen);
	assert(!state.windows[0].reported.minimized);
	assert(!state.windows[1].pid.has_value);
	assert(!state.windows[1].geometry.has_value);
	assert(state.windows[1].flags.floating);
	assert(state.windows[1].flags.urgent);
	assert(!state.windows[1].reported.maximized);
	assert(state.workspaces.len == 2);
	assert(state.workspaces[0].active && state.workspaces[0].visible);
	assert(state.workspaces[0].window_count == 1);
	assert(state.workspaces[1].window_count == 1);
	assert(!state.workspaces[1].visible);
	assert(!state.workspaces[1].index.has_value);
	assert(state.outputs[0].active_workspace_id == "1");
}
