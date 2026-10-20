module bleu::compositor::sway_test @feat(POSIX);
import bleu::compositor, bleu::compositor::backend, bleu::compositor::sway, bleu::compositor::wire, bleu::compositor::i3ipc, std::core::test;

fn sway::Replies fixture_replies() @private
{
	return {
		.workspaces = wire::parse_document((String)$embed("../tests/fixtures/sway/workspaces.json"), "workspaces")!!,
		.outputs = wire::parse_document((String)$embed("../tests/fixtures/sway/outputs.json"), "outputs")!!,
		.tree = wire::parse_document((String)$embed("../tests/fixtures/sway/tree.json"), "tree")!!,
		.inputs = wire::parse_document((String)$embed("../tests/fixtures/sway/inputs.json"), "inputs")!!,
	};
}

fn void tree_walk_finds_views_and_the_focus_path() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	@pool()
	{
		compositor::Model model = sway::build(&arena, compositor::Kind.SWAY, fixture_replies())!!;
		test::@check(model.kind == compositor::Kind.SWAY, "the kind is sway");
		test::eq((sz)3, model.windows.len);
		test::@check(model.windows[0].id == "10" && model.windows[0].app_id == "foot", "a Wayland view has its app_id");
		test::@check(model.windows[0].pid.has_value && model.windows[0].pid.value == 4242, "the pid of a view is read");
		test::@check(
			model.windows[1].id == "11" && model.windows[1].app_id == "Firefox",
			"an X11 view takes its class"
		);
		test::@check(model.windows[1].focused, "the focus path ends at the focused window");
		test::@check(!model.windows[0].focused && !model.windows[2].focused, "other windows are not focused");
		test::@check(
			model.windows[0].workspace_id == "1" && model.windows[0].output == "DP-1",
			"a window knows its workspace and output"
		);
		test::@check(
			model.windows[2].floating && model.windows[2].app_id == "gnome-calculator",
			"a window in a floating container floats"
		);
		test::@check(
			model.windows[1].urgent.has_value && model.windows[1].urgent.value,
			"urgency is read from the node"
		);
		test::@check(
			!model.windows[0].floating && !model.windows[1].floating,
			"a tiled window is not floating: sway writes floating auto_off on it"
		);
		test::@check(
			model.windows[1].fullscreen.has_value && !model.windows[1].fullscreen.value,
			"fullscreen_mode 0 is not fullscreen"
		);
		test::@check(!model.windows[1].maximized.has_value, "sway does not report maximized");
		test::@check(
			model.windows[1].geometry.has_value && model.windows[1].geometry.value.x == 1280,
			"the rect is the geometry"
		);
		test::eq((sz)2, model.workspaces.len);
		test::@check(
			model.workspaces[0].id == "1" && model.workspaces[0].active && model.workspaces[0].focused,
			"the workspace is addressed by its name"
		);
		test::@check(
			model.workspaces[1].urgent.has_value && model.workspaces[1].urgent.value,
			"a workspace with urgency is urgent"
		);
		test::eq((sz)1, model.outputs.len);
		test::@check(model.outputs[0].name == "DP-1" && model.outputs[0].focused, "inactive outputs are left out");
		test::@check(model.outputs[0].active_workspace == "1", "an output names its current workspace");
		test::@check(model.layouts.current_name == "English (US)", "the keyboard's active layout name is read");
		test::@check(model.layouts.current.has_value && model.layouts.current.value == 0, "the layout index is read");
		test::eq((sz)2, model.layouts.names.len);
	};
}

fn void i3_has_no_layouts() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	@pool()
	{
		sway::Replies replies = fixture_replies();
		replies.inputs = null;
		compositor::Model model = sway::build(&arena, compositor::Kind.I3, replies)!!;
		test::@check(model.kind == compositor::Kind.I3, "the kind is i3");
		test::eq((sz)0, model.layouts.names.len);
	};
}

fn void window_and_workspace_events_are_applied() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	@pool()
	{
		compositor::Model model = sway::build(&arena, compositor::Kind.SWAY, fixture_replies())!!;
		// The captured events, one per line, in the order they were sent by sway.
		Splitter lines          = ((String)$embed("../tests/fixtures/sway/events.txt")).tokenize("\n");
		String[4] names         = { "window", "workspace", "input", "window" };
		backend::Refresh[4] outcomes;
		for (int i = 0; i < 4; i++)
		{
			String line = lines.next()!!;
			outcomes[i] = sway::apply(&model, &arena, { .name = names[i], .payload = line });
		}
		test::@check(outcomes[0] == backend::Refresh.UPDATED, "the focus event is applied in place");
		test::@check(outcomes[1] == backend::Refresh.UPDATED, "the workspace focus is applied in place");
		test::@check(model.workspaces[1].focused && !model.workspaces[0].focused, "focus moves to the named workspace");
		test::@check(model.workspaces[1].active, "the focused workspace is shown on its output");
		test::@check(outcomes[2] == backend::Refresh.UPDATED, "the layout change is applied");
		test::@check(model.layouts.current_name == "German (Germany)", "the layout name follows the event");
		test::@check(outcomes[3] == backend::Refresh.UPDATED, "the close event is applied");
		test::eq((sz)2, model.windows.len);
		test::@check(
			model.windows[0].id == "11" && model.windows[0].focused,
			"container 11 keeps the focus the focus event gave it"
		);
		test::@check(!model.windows[1].focused, "the other window is not focused");
		backend::RawEvent init = {
			.name = "workspace",
			.payload = "{\"change\":\"init\",\"current\":{\"name\":\"9\"}}"
		};
		test::@check(
			sway::apply(&model, &arena, init) == backend::Refresh.REFRESH_NEEDED,
			"a workspace init asks for a snapshot"
		);
		backend::RawEvent broken = { .name = "window", .payload = "{\"change\":" };
		test::@check(
			sway::apply(&model, &arena, broken) == backend::Refresh.REFRESH_NEEDED,
			"an unreadable payload asks for a snapshot"
		);
	};
}

fn void input_layout_events_update_the_layout() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	@pool()
	{
		compositor::Model model = sway::build(&arena, compositor::Kind.SWAY, fixture_replies())!!;
		backend::RawEvent event = {
			.name = "input",
			.payload = "{\"change\":\"xkb_layout\",\"input\":{\"identifier\":\"1:1:AT_Translated_Set_2_keyboard\",\"type\":\"keyboard\",\"xkb_active_layout_name\":\"German (Germany)\",\"xkb_layout_names\":[\"English (US)\",\"German (Germany)\"],\"xkb_active_layout_index\":1}}"
		};
		test::@check(sway::apply(&model, &arena, event) == backend::Refresh.UPDATED, "a layout change is applied");
		test::@check(
			model.layouts.current.value == 1 && model.layouts.current_name == "German (Germany)",
			"the index and name follow the event"
		);
		// The model holds one keyboard: a layout change on another keyboard leaves it alone.
		backend::RawEvent other = {
			.name = "input",
			.payload = "{\"change\":\"xkb_layout\",\"input\":{\"identifier\":\"1133:16505:Logitech_USB_Mouse\",\"type\":\"keyboard\",\"xkb_active_layout_name\":\"Russian\",\"xkb_layout_names\":[\"Russian\"],\"xkb_active_layout_index\":0}}"
		};
		test::@check(
			sway::apply(&model, &arena, other) == backend::Refresh.NONE,
			"another keyboard's layout is ignored"
		);
		test::@check(model.layouts.current_name == "German (Germany)", "the held keyboard keeps its layout");
	};
}

fn void frames_decode_to_the_window_events() @test
{
	char[] frame = i3ipc::encode(mem, i3ipc::EVENT_BIT | (uint)i3ipc::EventType.WINDOW, "{\"change\":\"close\"}");
	defer alloc::free(mem, frame.ptr);
	i3ipc::Header header = i3ipc::decode_header((String)frame)!!;
	test::@check(header.is_event(), "the frame is an event");
	test::@check(i3ipc::event_name(header.event_type()) == "window", "the event is a window event");
}

fn void a_floating_event_reads_the_floating_field() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	@pool()
	{
		compositor::Model model = sway::build(&arena, compositor::Kind.SWAY, fixture_replies())!!;
		// sway sends the window's own container: its `floating` says whether it floats now.
		backend::RawEvent floats = {
			.name = "window",
			.payload = "{\"change\":\"floating\",\"container\":{\"id\":10,\"type\":\"con\",\"floating\":\"user_on\"}}"
		};
		test::@check(sway::apply(&model, &arena, floats) == backend::Refresh.UPDATED, "a floating change is applied");
		test::@check(model.windows[0].floating, "user_on makes the window float");
		backend::RawEvent tiles = {
			.name = "window",
			.payload = "{\"change\":\"floating\",\"container\":{\"id\":10,\"type\":\"con\",\"floating\":\"auto_off\"}}"
		};
		test::@check(sway::apply(&model, &arena, tiles) == backend::Refresh.UPDATED, "a tiling change is applied");
		test::@check(!model.windows[0].floating, "auto_off makes it tiled again");
	};
}

fn void a_workspace_focus_moves_the_shown_workspace_and_output() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	@pool()
	{
		compositor::Model model = sway::build(&arena, compositor::Kind.SWAY, fixture_replies())!!;
		test::@check(model.outputs[0].active_workspace == "1" && model.outputs[0].focused, "the start state shows 1");
		backend::RawEvent focus = {
			.name = "workspace",
			.payload = "{\"change\":\"focus\",\"current\":{\"id\":4,\"name\":\"2:web\",\"output\":\"DP-1\",\"visible\":true,\"focused\":true}}"
		};
		test::@check(sway::apply(&model, &arena, focus) == backend::Refresh.UPDATED, "the workspace focus is applied");
		test::@check(
			model.outputs[0].active_workspace == "2:web",
			"the output now shows the workspace that was focused"
		);
		test::@check(model.outputs[0].focused, "the output of the focused workspace holds the focus");
	};
}

fn void a_fullscreen_event_without_a_mode_asks_for_a_snapshot() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	@pool()
	{
		compositor::Model model = sway::build(&arena, compositor::Kind.SWAY, fixture_replies())!!;
		backend::RawEvent bare = {
			.name = "window",
			.payload = "{\"change\":\"fullscreen_mode\",\"container\":{\"id\":10,\"type\":\"con\"}}"
		};
		test::@check(
			sway::apply(&model, &arena, bare) == backend::Refresh.REFRESH_NEEDED,
			"a fullscreen event with no mode asks for a snapshot"
		);
		test::@check(model.windows[0].fullscreen.has_value, "the window's fullscreen state is not invented");
	};
}