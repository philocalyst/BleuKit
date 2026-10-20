module bleu::windows_win32_rules_test;
import std::collections::list, bleu::error, bleu::windows, bleu::windows::win32_rules;

fn void alt_tab_follows_the_raymond_chen_rules() @test
{
	win32_rules::WindowFacts plain = { .visible = true, .owner_is_self = true };
	assert(win32_rules::is_alt_tab_window(plain));
	assert(!win32_rules::is_alt_tab_window({ .visible = false, .owner_is_self = true }));
	assert(!win32_rules::is_alt_tab_window({ .visible = true, .cloaked = true, .owner_is_self = true }));
	assert(!win32_rules::is_alt_tab_window({ .visible = true, .owner_is_self = false }));
	assert(!win32_rules::is_alt_tab_window({ .visible = true, .tool_window = true, .owner_is_self = true }));
	assert(win32_rules::is_alt_tab_window(
		{ .visible = true, .tool_window = true, .app_window = true, .owner_is_self = true }
	));
	assert(win32_rules::is_alt_tab_window({ .visible = true, .app_window = true, .owner_is_self = true }));
}

fn void only_window_objects_of_the_listed_events_are_relevant() @test
{
	assert(win32_rules::is_relevant_event(win32_rules::EVENT_SYSTEM_FOREGROUND, win32_rules::OBJID_WINDOW));
	assert(win32_rules::is_relevant_event(win32_rules::EVENT_OBJECT_UNCLOAKED, win32_rules::OBJID_WINDOW));
	assert(!win32_rules::is_relevant_event(win32_rules::EVENT_OBJECT_CREATE, 0x0007));
	assert(!win32_rules::is_relevant_event(0x0004, win32_rules::OBJID_WINDOW));
}

fn void window_ids_round_trip() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 1024);
	defer arena.free();
	Allocator allocator = &arena;
	String text         = win32_rules::format_handle(0x55d1c0a4e2b0, allocator);
	assert(text == "0x55d1c0a4e2b0");
	assert(win32_rules::parse_handle(text)!! == 0x55d1c0a4e2b0);
	assert(win32_rules::parse_handle("0X1F")!! == 31);
	expect_invalid_id("1234");
	expect_invalid_id("0xZZ");
	expect_invalid_id("0x 1");
}

fn void expect_invalid_id(String text) @private
{
	ulong? parsed = win32_rules::parse_handle(text);
	if (catch err = parsed)
	{
		assert(err == error::INVALID_ARGUMENT);
	}
	else
	{
		unreachable("accepted a window id that is not one");
	}
}

fn void executable_names_drop_directory_and_extension() @test
{
	assert(win32_rules::executable_name("C:\\Program Files\\App\\firefox.exe") == "firefox");
	assert(win32_rules::executable_name("C:\\tools\\Code.EXE") == "Code");
	assert(win32_rules::executable_name("notepad") == "notepad");
	assert(win32_rules::executable_name("") == "");
}

fn void workspaces_group_windows_by_desktop() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	Allocator allocator = &arena;
	windows::Window[3] listed = {
		{ .id = "0x1", .workspace_id = "{a}" },
		{ .id = "0x2", .workspace_id = "{b}" },
		{ .id = "0x3", .workspace_id = "{a}" },
	};
	windows::Workspace[] found = win32_rules::workspaces_of(listed[..], "{a}", "{a}", allocator);
	assert(found.len == 2);
	assert(found[0].id == "{a}" && found[0].window_count == 2 && found[0].active && found[0].visible);
	assert(found[1].id == "{b}" && found[1].window_count == 1 && !found[1].active && !found[1].visible);
	assert(!found[0].index.has_value);
	assert(!found[0].urgent.has_value);
}