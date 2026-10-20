module bleu::compositor::niri_test @feat(POSIX);
import bleu::compositor, bleu::compositor::backend, bleu::compositor::niri, bleu::compositor::wire, bleu::error, std::collections::object, std::core::test;

// The model of the fixture session, built from the captured replies.
fn compositor::Model fixture_model(Allocator allocator) @private
{
	niri::Replies replies = {
		.workspaces = niri_list("workspaces_reply", "Workspaces"),
		.windows = niri_list("windows_reply", "Windows"),
		.outputs = niri_object("outputs_reply", "Outputs"),
		.layouts = niri_object("layouts_reply", "KeyboardLayouts"),
	};
	return niri::build(allocator, replies)!!;
}

// The `Ok` payload of a captured reply, then its member `key` (a list).
fn Object* niri_list(String name, String key) @private
{
	return wire::array_member(niri_payload(name), key)!!;
}

fn Object* niri_object(String name, String key) @private
{
	return wire::object_member(niri_payload(name), key)!!;
}

fn Object* niri_payload(String name) @private
{
	return niri::unwrap(wire::parse_document(niri_text(name), name)!!, name)!!;
}

fn String niri_text(String name) @private
{
	switch
	{
		case name == "workspaces_reply": return (String)$embed("../tests/fixtures/niri/workspaces_reply.json");
		case name == "windows_reply": return (String)$embed("../tests/fixtures/niri/windows_reply.json");
		case name == "outputs_reply": return (String)$embed("../tests/fixtures/niri/outputs_reply.json");
		default: return (String)$embed("../tests/fixtures/niri/layouts_reply.json");
	}
}

fn compositor::Output* output_named(compositor::Model* model, String name) @private
{
	for (sz i = 0; i < model.outputs.len; i++)
	{
		if (model.outputs[i].name == name) return &model.outputs[i];
	}
	return null;
}

fn void replies_are_unwrapped_and_an_err_is_a_failure() @test
{
	@pool()
	{
		Object* failed = wire::parse_document((String)$embed("../tests/fixtures/niri/err_reply.json"), "err")!!;
		test::@error(niri::unwrap(failed, "FocusWindow"), error::BACKEND_FAILURE);
		Object* bare = wire::parse_document("{\"Other\": 1}", "bare")!!;
		test::@error(niri::unwrap(bare, "x"), error::PROTOCOL);
		Object* handled = wire::parse_document("{\"Ok\":\"Handled\"}", "ok")!!;
		test::@check(niri::unwrap(handled, "x")!!.is_string(), "Handled is an Ok string");
	};
}

fn void snapshot_reads_workspaces_windows_outputs_and_layouts() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	@pool()
	{
		compositor::Model model = fixture_model(&arena);
		test::@check(model.kind == compositor::Kind.NIRI, "the kind is niri");
		test::eq((sz)3, model.workspaces.len);
		test::@check(
			model.workspaces[0].id == "1" && model.workspaces[0].name == "",
			"an unnamed workspace has an empty name"
		);
		test::@check(model.workspaces[0].active && model.workspaces[0].focused, "workspace 1 is active and focused");
		test::@check(model.workspaces[1].urgent.value, "urgency is reported");
		test::eq((sz)2, model.windows.len);
		test::@check(
			model.windows[0].focused && model.windows[0].pid.value == 4242,
			"the focused window carries its pid"
		);
		test::@check(model.windows[0].output == "eDP-1", "a window's output is its workspace's output");
		test::@check(
			model.windows[1].title == "" && !model.windows[1].pid.has_value,
			"null title and pid are empty and absent"
		);
		test::@check(model.windows[1].output == "HDMI-A-1", "a window on another output names it");
		test::@check(
			!model.windows[0].geometry.has_value && !model.windows[0].fullscreen.has_value,
			"niri reports no geometry or fullscreen state"
		);
		test::eq((sz)2, model.outputs.len);
		// The outputs come from a JSON object, so their order is the object's own, not the order of the names.
		compositor::Output* laptop = output_named(&model, "eDP-1");
		compositor::Output* hdmi   = output_named(&model, "HDMI-A-1");
		test::@check(laptop != null && hdmi != null, "both outputs are listed by name");
		test::@check(
			laptop.geometry.has_value && laptop.geometry.value.width == 1920,
			"a logical output has a geometry"
		);
		test::@check(!hdmi.geometry.has_value, "an output that is off has no geometry");
		test::@check(
			laptop.active_workspace == "1" && laptop.focused,
			"the output names its active workspace and is focused"
		);
		test::@check(
			model.layouts.current_name == "English (US)" && model.layouts.current.value == 0,
			"the current layout is names[current_idx]"
		);
		test::eq((sz)2, model.layouts.names.len);
	};
}

fn void events_update_the_retained_model() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	@pool()
	{
		compositor::Model model = fixture_model(&arena);
		Splitter lines          = ((String)$embed("../tests/fixtures/niri/events.jsonl")).tokenize("\n");
		backend::Refresh[8] outcomes;
		for (int i = 0; i < 8; i++)
		{
			String line             = lines.next()!!;
			backend::RawEvent event = niri::parse_event(line)!!;
			outcomes[i] = niri::apply(&model, &arena, event);
		}
		test::@check(outcomes[0] == backend::Refresh.UPDATED, "WorkspaceActivated is applied");
		test::@check(model.workspaces[2].focused && model.workspaces[2].active, "workspace 3 is focused on its output");
		test::@check(!model.workspaces[0].focused, "the old focus is cleared");
		test::@check(outcomes[1] == backend::Refresh.UPDATED, "WindowFocusChanged is applied in place");
		test::@check(outcomes[2] == backend::Refresh.UPDATED, "WindowOpenedOrChanged adds a window");
		test::@check(outcomes[3] == backend::Refresh.UPDATED, "WindowUrgencyChanged is applied");
		test::@check(outcomes[4] == backend::Refresh.UPDATED && model.windows.len == 2, "WindowClosed removes it");
		// Window 9 kept the focus that WindowFocusChanged gave it; window 7 is gone, so 9 is now first.
		test::@check(model.windows[0].id == "9" && model.windows[0].focused, "window 9 still holds the focus");
		test::@check(!model.windows[1].focused, "the window opened later is not focused");
		test::@check(
			model.windows[1].id == "11" && model.windows[1].title == "New, window",
			"the opened window keeps its id and its title with the comma"
		);
		test::@check(model.windows[1].urgent.has_value && model.windows[1].urgent.value, "the opened window is urgent");
		test::@check(
			outcomes[5] == backend::Refresh.UPDATED && model.layouts.current_name == "Russian",
			"KeyboardLayoutSwitched names the layout"
		);
		test::@check(outcomes[6] == backend::Refresh.NONE, "casts change nothing the model holds");
		test::@check(outcomes[7] == backend::Refresh.NONE, "an overview change changes nothing");
	};
}

fn void an_unknown_or_malformed_event_is_handled() @test
{
	@pool()
	{
		test::@error(niri::parse_event("not json"), error::PROTOCOL);
		test::@error(niri::parse_event("{\"A\":1,\"B\":2}"), error::PROTOCOL);
	};
}

fn void action_requests_have_the_documented_shape() @test
{
	@pool()
	{
		test::@check(niri::focus_window_request("7") == "{\"Action\":{\"FocusWindow\":{\"id\":7}}}", "FocusWindow");
		test::@check(niri::close_window_request("7") == "{\"Action\":{\"CloseWindow\":{\"id\":7}}}", "CloseWindow");
		test::@check(
			niri::switch_workspace_request("3") == "{\"Action\":{\"FocusWorkspace\":{\"reference\":{\"Id\":3}}}}",
			"FocusWorkspace"
		);
		test::@check(
			niri::move_window_request(
				"7",
				"3"
			) == "{\"Action\":{\"MoveWindowToWorkspace\":{\"window_id\":7,\"reference\":{\"Id\":3},\"focus\":false}}}",
			"MoveWindowToWorkspace"
		);
		test::@check(
			niri::set_layout_request(1) == "{\"Action\":{\"SwitchLayout\":{\"layout\":{\"Index\":1}}}}",
			"SwitchLayout"
		);
		test::@check(
			niri::toggle_floating_request("7") == "{\"Action\":{\"ToggleWindowFloating\":{\"id\":7}}}",
			"ToggleWindowFloating"
		);
		test::@check(
			niri::toggle_fullscreen_request("7") == "{\"Action\":{\"FullscreenWindow\":{\"id\":7}}}",
			"FullscreenWindow"
		);
	};
}

fn void a_workspace_activation_moves_the_shown_workspace_of_its_output() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	@pool()
	{
		compositor::Model model = fixture_model(&arena);
		compositor::Output* laptop  = output_named(&model, "eDP-1");
		compositor::Output* monitor = output_named(&model, "HDMI-A-1");
		test::@check(laptop.active_workspace == "1", "the laptop starts out showing workspace 1");
		// Workspace 2 ("chat") is on eDP-1 and takes focus.
		backend::RawEvent activated = niri::parse_event("{\"WorkspaceActivated\":{\"id\":2,\"focused\":true}}")!!;
		test::@check(niri::apply(&model, &arena, activated) == backend::Refresh.UPDATED, "the activation is applied");
		test::@check(laptop.active_workspace == "2", "the laptop now shows workspace 2");
		test::@check(laptop.focused, "the output of the focused workspace holds the focus");
		test::@check(!monitor.focused, "the other output does not hold the focus");
		test::@check(monitor.active_workspace == "3", "the other output keeps its workspace");
	};
}

fn void an_out_of_range_layout_index_names_no_layout() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	@pool()
	{
		niri::Replies replies = {
			.workspaces = niri_list("workspaces_reply", "Workspaces"),
			.windows = niri_list("windows_reply", "Windows"),
			.outputs = niri_object("outputs_reply", "Outputs"),
			.layouts = wire::parse_document(
				"{\"names\":[\"English (US)\",\"Russian\"],\"current_idx\":5}",
				"layouts"
			)!!,
		};
		compositor::Model model = niri::build(&arena, replies)!!;
		test::eq((sz)2, model.layouts.names.len);
		test::@check(!model.layouts.current.has_value, "an index outside the list is absent");
		test::@check(model.layouts.current_name == "", "and it names no layout");
	};
}
