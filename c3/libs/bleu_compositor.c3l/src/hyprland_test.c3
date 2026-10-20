module bleu::compositor::hyprland_test @feat(POSIX);
import bleu::compositor, bleu::compositor::backend, bleu::compositor::hyprland, bleu::compositor::wire, bleu::error, std::core::test, std::collections::object;

// The model of the fixture session, built from the captured replies.
fn compositor::Model fixture_model(Allocator allocator) @private
{
	hyprland::Replies replies = {
		.clients = wire::parse_document((String)$embed("../tests/fixtures/hyprland/clients.json"), "clients")!!,
		.active = wire::parse_document((String)$embed("../tests/fixtures/hyprland/activewindow.json"), "active")!!,
		.workspaces = wire::parse_document(
			(String)$embed("../tests/fixtures/hyprland/workspaces.json"),
			"workspaces"
		)!!,
		.monitors = wire::parse_document((String)$embed("../tests/fixtures/hyprland/monitors.json"), "monitors")!!,
		.devices = wire::parse_document((String)$embed("../tests/fixtures/hyprland/devices.json"), "devices")!!,
	};
	return hyprland::build(allocator, replies)!!;
}

fn void snapshot_reads_windows_workspaces_outputs_and_layouts() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	Allocator allocator = &arena;
	@pool()
	{
		compositor::Model model = fixture_model(allocator);
		test::@check(model.kind == compositor::Kind.HYPRLAND, "the kind is Hyprland");
		test::eq((sz)2, model.windows.len);
		test::@check(model.windows[0].id == "0x55d1c0a4e2b0", "the first window is addressed by its address");
		test::@check(model.windows[0].focused, "activewindow marks the focused window");
		test::@check(!model.windows[1].focused, "only one window is focused");
		test::@check(model.windows[0].pid.has_value && model.windows[0].pid.value == 4242, "pid comes from the client");
		test::@check(model.windows[0].output == "DP-1", "the window's monitor id maps to its name");
		test::@check(model.windows[1].workspace_id == "2", "the workspace is an id");
		test::@check(model.windows[1].floating, "a floating client is floating");
		test::@check(
			model.windows[1].fullscreen.value && model.windows[1].fullscreen.has_value,
			"fullscreen mode 2 is fullscreen"
		);
		test::@check(!model.windows[1].maximized.value, "fullscreen mode 2 is not maximized");
		test::@check(
			model.windows[0].geometry.has_value && model.windows[0].geometry.value.width == 1280,
			"geometry comes from size"
		);
		test::@check(!model.windows[0].urgent.has_value, "urgency is absent from a snapshot");
		test::eq((sz)2, model.workspaces.len);
		test::@check(
			model.workspaces[0].active && model.workspaces[0].focused,
			"workspace 1 is shown on the focused monitor"
		);
		test::@check(
			model.workspaces[1].active && !model.workspaces[1].focused,
			"workspace 2 is shown on another monitor"
		);
		test::@check(model.outputs[1].scale.value == 1.25, "a float scale is read as a float");
		test::@check(model.outputs[1].active_workspace == "2", "an output names its active workspace");
		test::@check(model.outputs[0].focused && !model.outputs[1].focused, "the focused monitor is marked");
		test::@check(model.layouts.current_name == "German", "the main keyboard's active keymap is the current layout");
		test::@check(!model.layouts.current.has_value, "Hyprland does not report the layout index");
		test::eq((sz)0, model.layouts.names.len);
	};
}

fn void event_lines_split_by_their_documented_field_counts() @test
{
	@pool()
	{
		backend::RawEvent open = hyprland::parse_event("openwindow>>0x1,3,kitty,Log: a, b, c")!!;
		test::@check(open.name == "openwindow", "the name is before the separator");
		test::@check(open.payload == "0x1,3,kitty,Log: a, b, c", "the payload is everything after the first separator");
		test::@error(hyprland::parse_event("notanevent"), error::PROTOCOL);
	};
}

fn void focus_inside_the_focused_workspace_is_applied_in_place() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	@pool()
	{
		compositor::Model model = fixture_model(&arena);
		backend::RawEvent event = hyprland::parse_event("activewindowv2>>0x55d1c0a4e2b0")!!;
		test::@check(
			hyprland::apply(&model, &arena, event) == backend::Refresh.UPDATED,
			"focus on the focused workspace is applied in place"
		);
		test::@check(model.windows[0].focused, "the window is focused");
	};
}

fn void focus_onto_another_workspace_asks_for_a_snapshot() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	@pool()
	{
		compositor::Model model = fixture_model(&arena);
		backend::RawEvent event = hyprland::parse_event("activewindowv2>>0x55d1c0a50f70")!!;
		test::@check(
			hyprland::apply(&model, &arena, event) == backend::Refresh.REFRESH_NEEDED,
			"a window on an unfocused workspace needs a snapshot"
		);
	};
}

fn void window_events_update_the_model() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	@pool()
	{
		compositor::Model model = fixture_model(&arena);
		test::@check(
			hyprland::apply(
				&model,
				&arena,
				hyprland::parse_event("openwindow>>0x55d1c0a53000,1,kitty,Log: a, b, c")!!
			) == backend::Refresh.UPDATED,
			"openwindow adds a window"
		);
		test::eq((sz)3, model.windows.len);
		test::@check(model.windows[2].title == "Log: a, b, c", "the title keeps its commas");
		test::@check(
			model.windows[2].workspace_id == "1" && model.windows[2].output == "DP-1",
			"the new window takes its workspace's id and output"
		);
		test::@check(!model.windows[2].pid.has_value, "an opened window has no pid until a snapshot");
		test::@check(
			hyprland::apply(
				&model,
				&arena,
				hyprland::parse_event("windowtitlev2>>0x55d1c0a53000,Docs, part 3")!!
			) == backend::Refresh.UPDATED,
			"windowtitlev2 renames"
		);
		test::@check(model.windows[2].title == "Docs, part 3", "the renamed title keeps its comma");
		test::@check(
			hyprland::apply(
				&model,
				&arena,
				hyprland::parse_event("urgent>>0x55d1c0a4e2b0")!!
			) == backend::Refresh.UPDATED,
			"urgent is applied"
		);
		test::@check(model.windows[0].urgent.has_value && model.windows[0].urgent.value, "the window is urgent");
		test::@check(
			hyprland::apply(
				&model,
				&arena,
				hyprland::parse_event("changefloatingmode>>0x55d1c0a4e2b0,1")!!
			) == backend::Refresh.UPDATED,
			"floating is applied"
		);
		test::@check(model.windows[0].floating, "the window floats");
		test::@check(
			hyprland::apply(&model, &arena, hyprland::parse_event("fullscreen>>1")!!) == backend::Refresh.UPDATED,
			"fullscreen applies to the focused window"
		);
		test::@check(model.windows[0].fullscreen.value, "the focused window is fullscreen");
		test::@check(
			hyprland::apply(
				&model,
				&arena,
				hyprland::parse_event("movewindowv2>>0x55d1c0a4e2b0,2,2")!!
			) == backend::Refresh.UPDATED,
			"a move to a known workspace is applied"
		);
		test::@check(
			model.windows[0].workspace_id == "2" && model.windows[0].output == "DP-2",
			"the window moved with its output"
		);
		test::@check(
			hyprland::apply(
				&model,
				&arena,
				hyprland::parse_event("closewindow>>0x55d1c0a53000")!!
			) == backend::Refresh.UPDATED,
			"closewindow removes a window"
		);
		test::eq((sz)2, model.windows.len);
	};
}

fn void layout_and_model_wide_events() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	@pool()
	{
		compositor::Model model = fixture_model(&arena);
		test::@check(
			hyprland::apply(
				&model,
				&arena,
				hyprland::parse_event("activelayout>>main-keyboard,English (US)")!!
			) == backend::Refresh.UPDATED,
			"activelayout is applied"
		);
		test::@check(model.layouts.current_name == "English (US)", "the layout name is the event's second field");
		test::@check(
			hyprland::apply(
				&model,
				&arena,
				hyprland::parse_event("workspacev2>>3,3")!!
			) == backend::Refresh.REFRESH_NEEDED,
			"a workspace change asks for a snapshot"
		);
		test::@check(
			hyprland::apply(
				&model,
				&arena,
				hyprland::parse_event("configreloaded>>")!!
			) == backend::Refresh.REFRESH_NEEDED,
			"a config reload asks for a snapshot"
		);
		test::@check(
			hyprland::apply(&model, &arena, hyprland::parse_event("pin>>0x55d1c0a4e2b0,1")!!) == backend::Refresh.NONE,
			"events the model does not hold change nothing"
		);
	};
}