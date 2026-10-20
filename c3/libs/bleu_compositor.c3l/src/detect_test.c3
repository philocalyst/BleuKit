module bleu::compositor::detect_test @feat(POSIX);
import bleu::compositor, std::core::test;

fn compositor::Environment none() @private => { };

fn void hyprland_needs_its_runtime_dir() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	compositor::Environment environment = none();
	environment.hyprland_signature = "abc_123";
	compositor::Detection missing = compositor::detect_from(environment, &arena);
	test::@check(missing.kind == compositor::Kind.HYPRLAND, "the signature names Hyprland");
	test::@check(missing.socket.len == 0, "no runtime dir means no socket path");
	environment.runtime_dir = "/run/user/1000";
	compositor::Detection found = compositor::detect_from(environment, &arena);
	test::@check(
		found.socket == "/run/user/1000/hypr/abc_123/.socket.sock",
		"the command socket is under the instance directory"
	);
	test::@check(
		found.event_socket == "/run/user/1000/hypr/abc_123/.socket2.sock",
		"the event socket is the second socket"
	);
}

fn void socket_variables_win_in_order() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	compositor::Environment environment = none();
	environment.sway_socket = "/run/user/1000/sway-ipc.sock";
	environment.niri_socket = "/run/user/1000/niri.sock";
	compositor::Detection sway = compositor::detect_from(environment, &arena);
	test::@check(sway.kind == compositor::Kind.SWAY, "sway is found before niri");
	test::@check(sway.socket == sway.event_socket, "sway uses one socket for both");
	environment.sway_socket = "";
	compositor::Detection niri = compositor::detect_from(environment, &arena);
	test::@check(
		niri.kind == compositor::Kind.NIRI && niri.socket == "/run/user/1000/niri.sock",
		"niri is found when sway is not"
	);
	environment.niri_socket = "";
	environment.i3_socket = "/run/user/1000/i3.sock";
	test::@check(compositor::detect_from(environment, &arena)
		.kind == compositor::Kind.I3, "i3 is found last among the sockets");
}

fn void desktop_hints_name_river_and_dwl_without_a_socket() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	compositor::Environment environment = none();
	environment.desktop = "river";
	compositor::Detection river = compositor::detect_from(environment, &arena);
	test::@check(river.kind == compositor::Kind.RIVER && river.socket.len == 0, "river is named but has no socket");
	environment.desktop = "gnome:dwl";
	test::@check(compositor::detect_from(environment, &arena)
		.kind == compositor::Kind.DWL, "dwl is found among colon-separated names");
	environment.desktop = "GNOME";
	test::@check(compositor::detect_from(environment, &arena)
		.kind == compositor::Kind.NONE, "an unrelated desktop is not a compositor");
	environment.desktop = "sway";
	compositor::Detection hint = compositor::detect_from(environment, &arena);
	test::@check(
		hint.kind == compositor::Kind.SWAY && hint.socket.len == 0,
		"a sway hint without SWAYSOCK has no socket"
	);
}