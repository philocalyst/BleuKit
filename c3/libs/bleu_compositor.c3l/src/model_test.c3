module bleu::compositor::model_test @feat(POSIX);
import bleu::compositor, std::core::test;

fn void clone_shares_no_memory_with_the_original() @test
{
	DynamicArenaAllocator source;
	source.init(mem, 4096);
	defer source.free();
	DynamicArenaAllocator copies;
	copies.init(mem, 4096);
	defer copies.free();
	Allocator source_allocator = &source;
	Allocator copy_allocator   = &copies;

	compositor::Workspace[1] workspaces = {
		{
			.id = "1".copy(source_allocator),
			.name = "one".copy(source_allocator),
			.output = "DP-1".copy(source_allocator),
			.active = true,
			.focused = true
		}
	};
	compositor::Window[1] windows = {
		{
			.id = "0x1".copy(source_allocator),
			.title = "before".copy(source_allocator),
			.workspace_id = "1".copy(source_allocator)
		}
	};
	compositor::Model original = {
		.kind = compositor::Kind.HYPRLAND,
		.workspaces = workspaces[..],
		.windows = windows[..],
		.outputs = { },
		.layouts = { .names = { }, .current_name = "English".copy(source_allocator) },
	};
	compositor::Model copy = original.clone(copy_allocator);
	original.windows[0].title = "after".copy(source_allocator);
	original.workspaces[0].output = "HDMI-A-1".copy(source_allocator);
	test::@check(copy.windows[0].title == "before", "the copy keeps the title it had");
	test::@check(copy.workspaces[0].output == "DP-1", "the copy keeps the output it had");
	test::@check(copy.windows[0].id == "0x1" && copy.workspaces[0].focused, "the other fields are copied");
	test::@check(copy.layouts.current_name == "English", "layouts are copied");
	test::@check(copy.windows.ptr != original.windows.ptr, "the copy has its own window array");
}