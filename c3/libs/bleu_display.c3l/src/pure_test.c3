module bleu::display::pure_test;
import bleu::display, bleu::display::wayland_convert, bleu::error, std::collections::maybe, std::core::test, std::time, std::time::clock;

// A 1920x1080 mode at 60 Hz, the common case.
fn display::Mode fhd60() => { .width = 1920, .height = 1080, .refresh = 60000 };

fn void transform_swaps_for_quarter_turns() @test
{
	assert(!display::Transform.NORMAL.quarter_turn() && !display::Transform.R180.quarter_turn()
		&& !display::Transform.FLIPPED.quarter_turn());
	assert(display::Transform.R90.quarter_turn() && display::Transform.R270.quarter_turn()
		&& display::Transform.FLIPPED_R90.quarter_turn());
	display::Extent e = display::logical_extent(fhd60(), display::Transform.R90, 1.5);
	assert(e.width == 720 && e.height == 1280);
	display::Extent n = display::logical_extent(fhd60(), display::Transform.NORMAL, 1.0);
	assert(n.width == 1920 && n.height == 1080);
}

fn void scale_is_recovered_from_the_logical_width() @test
{
	display::Mode uhd = { .width = 3840, .height = 2160, .refresh = 60000 };
	assert(display::scale_from_logical_width(uhd, display::Transform.NORMAL, 1920) == 2.0);
	assert(display::scale_from_logical_width(uhd, display::Transform.R90, 1080) == 2.0);
	assert(display::scale_from_logical_width(uhd, display::Transform.NORMAL, 0) == 0.0);
}

fn void overlapping_outputs_are_refused() @test
{
	display::Rect[2] rects = { { 0, 0, 1920, 1080 }, { 1000, 0, 1920, 1080 } };
	test::@error(display::validate_layout(rects[..]), error::INVALID_ARGUMENT);
}

fn void touching_outputs_are_one_desktop() @test
{
	display::Rect[2] rects = { { 0, 0, 1920, 1080 }, { 1920, 0, 1920, 1080 } };
	display::validate_layout(rects[..])!!;
	// Stacked vertically with a shared edge of positive length is also connected.
	display::Rect[2] stacked = { { 0, 0, 1920, 1080 }, { 0, 1080, 1280, 720 } };
	display::validate_layout(stacked[..])!!;
}

fn void an_output_the_pointer_cannot_reach_is_refused() @test
{
	display::Rect[2] gapped = { { 0, 0, 1920, 1080 }, { 2000, 0, 1920, 1080 } };
	test::@error(display::validate_layout(gapped[..]), error::INVALID_ARGUMENT);
	display::Rect[1] none = { { 0, 0, 1920, 1080 } };
	display::validate_layout(none[..])!!;
	test::@error(display::validate_layout(none[0:0]), error::INVALID_ARGUMENT);
}

fn void origin_moves_to_the_anchor_or_the_bounding_box() @test
{
	display::Rect[2] rects = { { -1920, 0, 1920, 1080 }, { 0, 0, 1920, 1080 } };
	display::Offset box    = display::origin_offset(rects[..], -1);
	assert(box.x == 1920 && box.y == 0);
	display::Offset primary = display::origin_offset(rects[..], 1);
	assert(primary.x == 0 && primary.y == 0);
	assert(rects[0].shifted(box).x == 0);
}

fn void refresh_tolerance_separates_ntsc_rates() @test
{
	assert(display::refresh_matches(59940, 59940, display::DEFAULT_REFRESH_TOLERANCE));
	assert(display::refresh_matches(59950, 59940, display::DEFAULT_REFRESH_TOLERANCE));
	assert(!display::refresh_matches(60000, 59940, display::DEFAULT_REFRESH_TOLERANCE));
}

fn void mode_matching_is_exact_on_size() @test
{
	display::Mode[3] modes = { { 1920, 1080, 60000, true }, { 1920, 1080, 59940, false }, { 1280, 720, 60000, false } };
	display::Mode wanted   = { .width = 1920, .height = 1080, .refresh = 59940 };
	assert(display::find_mode(modes[..], wanted, display::DEFAULT_REFRESH_TOLERANCE).value == 1);
	display::Mode any_rate = { .width = 1920, .height = 1080, .refresh = 0 };
	assert(display::find_mode(modes[..], any_rate, display::DEFAULT_REFRESH_TOLERANCE).value == 0);
	display::Mode absent = { .width = 2560, .height = 1440, .refresh = 60000 };
	assert(!display::find_mode(modes[..], absent, display::DEFAULT_REFRESH_TOLERANCE).has_value);
}

// Two outputs: DP-1 enabled at the origin, HDMI-1 enabled to its right.
fn void two_outputs(display::Output[] outputs)
{
	outputs[0].id = "DP-1";
	outputs[0].enabled = true;
	outputs[0].x = 0;
	outputs[0].y = 0;
	outputs[0].current.set(fhd60());
	outputs[1].id = "HDMI-1";
	outputs[1].enabled = true;
	outputs[1].x = 1920;
	outputs[1].y = 0;
	outputs[1].current.set(fhd60());
}

fn void config_must_name_every_output_once() @test
{
	display::Output[2] outputs = { };
	two_outputs(outputs[..]);
	display::OutputChange[2] changes = { };
	changes[0] = { .output_id = "DP-1", .enabled = true, .mode = fhd60() };
	changes[1] = { .output_id = "HDMI-1", .enabled = true, .mode = fhd60(), .x = 1920 };
	display::validate_config(outputs[..], { .outputs = changes[..] })!!;
	test::@error(display::validate_config(outputs[..], { .outputs = changes[0:1] }), error::INVALID_ARGUMENT);
	changes[1].output_id = "DP-1";
	test::@error(display::validate_config(outputs[..], { .outputs = changes[..] }), error::INVALID_ARGUMENT);
	changes[1].output_id = "VGA-1";
	test::@error(display::validate_config(outputs[..], { .outputs = changes[..] }), error::INVALID_ARGUMENT);
}

fn void config_refuses_no_enabled_output_and_zero_scale() @test
{
	display::Output[2] outputs = { };
	two_outputs(outputs[..]);
	display::OutputChange[2] changes = { };
	changes[0] = { .output_id = "DP-1", .enabled = false };
	changes[1] = { .output_id = "HDMI-1", .enabled = false };
	test::@error(display::validate_config(outputs[..], { .outputs = changes[..] }), error::INVALID_ARGUMENT);
	changes[0] = { .output_id = "DP-1", .enabled = true, .mode = fhd60(), .scale = maybe::value(0.0) };
	changes[1] = { .output_id = "HDMI-1", .enabled = false };
	test::@error(display::validate_config(outputs[..], { .outputs = changes[..] }), error::INVALID_ARGUMENT);
}

fn void diff_sees_only_what_the_change_sets() @test
{
	display::Output[2] outputs = { };
	two_outputs(outputs[..]);
	display::State state       = { .outputs = outputs[..] };
	display::OutputChange same = { .output_id = "HDMI-1", .enabled = true, .mode = fhd60(), .x = 1920 };
	assert(!display::delta_of(outputs[1], same).differs());
	display::OutputChange moved = { .output_id = "HDMI-1", .enabled = true, .mode = fhd60(), .x = 0 };
	assert(display::delta_of(outputs[1], moved).position);
	display::OutputChange unset_scale = { .output_id = "HDMI-1", .enabled = true, .mode = fhd60(), .x = 1920 };
	assert(!display::delta_of(outputs[1], unset_scale).scale);
	@pool()
	{
		display::Config restored = display::config_from_state(state, tmem);
		assert(!display::config_changes(state, restored));
		assert(restored.outputs[0].output_id == "DP-1");
	};
}

fn void revert_fires_only_without_confirmation() @test
{
	display::RevertGuard guard;
	Clock start = (Clock)1_000_000_000;
	guard.arm(start, (Duration)15_000);
	assert(!guard.due(start));
	assert(guard.remaining(start) == (Duration)15_000);
	// Confirmed in time: the change stays and nothing is due.
	assert(guard.confirm(start + (Clock)5_000_000));
	assert(!guard.due(start + (Clock)60_000_000_000));
	// Not confirmed: due at the deadline, and a late confirmation is refused.
	guard.arm(start, (Duration)15_000);
	assert(guard.due(start + (Clock)15_000_000));
	assert(!guard.confirm(start + (Clock)20_000_000));
	assert(guard.due(start + (Clock)20_000_000));
	assert(guard.remaining(start + (Clock)20_000_000) == time::DURATION_ZERO);
	guard.disarm();
	assert(!guard.due(start + (Clock)60_000_000_000));
	assert(guard.remaining(start) == time::FOREVER);
}

fn void wire_values_map_to_the_display_types() @test
{
	assert(wayland_convert::transform_from_wire(3) == display::Transform.R270);
	assert(wayland_convert::transform_from_wire(7) == display::Transform.FLIPPED_R270);
	assert(wayland_convert::transform_from_wire(9) == display::Transform.NORMAL);
	assert(wayland_convert::transform_to_wire(display::Transform.FLIPPED_R180) == 6);
	assert(wayland_convert::refresh_from_wire(-5) == 0 && wayland_convert::refresh_from_wire(59940) == 59940);
}

fn void cancelled_configuration_is_retried_once() @test
{
	// The layout moved on while the attempt was out: retry at once with the new serial.
	assert(wayland_convert::after_cancel(false, 7, 8) == wayland_convert::CancelAction.RETRY_NOW);
	// Still on the attempt's serial: wait for the compositor to announce the new one.
	assert(wayland_convert::after_cancel(false, 7, 7) == wayland_convert::CancelAction.WAIT_FOR_SERIAL);
	// Already retried once: report it, do not loop.
	assert(wayland_convert::after_cancel(true, 7, 8) == wayland_convert::CancelAction.GIVE_UP);
}
fn void revert_window_maps_zero_to_the_default_and_refuses_negative() @test
{
	assert(display::revert_window(time::DURATION_ZERO)!! == display::DEFAULT_REVERT_AFTER);
	assert(display::revert_window(time::FOREVER)!! == time::FOREVER);
	test::@error(display::revert_window((Duration)-1), error::INVALID_ARGUMENT);
}

fn void forever_never_comes_due() @test
{
	// Before the fix, FOREVER wrapped the deadline into the past and the change was rolled back at once.
	display::RevertGuard guard;
	Clock start = (Clock)1_000_000_000;
	guard.arm(start, time::FOREVER);
	assert(!guard.due(start));
	assert(!guard.due(start + (Clock)1_000_000_000_000_000));
	assert(guard.remaining(start) != time::DURATION_ZERO);
	assert(guard.confirm(start + (Clock)5_000_000));
}

fn void the_deadline_is_one_instant_for_confirm_and_due() @test
{
	display::RevertGuard guard;
	Clock start = (Clock)1_000_000_000;
	guard.arm(start, (Duration)1);
	// Half a microsecond left is not yet due, and the caller must still wait for it.
	assert(!guard.due(start + (Clock)999));
	assert(guard.remaining(start + (Clock)999) == (Duration)1);
	// At the deadline the change is due and a confirmation is refused.
	assert(guard.due(start + (Clock)1000));
	assert(!guard.confirm(start + (Clock)1000));
	assert(guard.armed);
}

fn void deadlines_saturate_instead_of_wrapping() @test
{
	display::RevertGuard guard;
	Clock near_the_end = (Clock)0xFFFF_FFFF_FFFF_FFF0;
	guard.arm(near_the_end, (Duration)15_000_000);
	assert(!guard.due(near_the_end));
	assert(guard.remaining(near_the_end) != time::DURATION_ZERO);
}

fn void logical_size_and_scale_bounds_are_checked() @test
{
	display::Output[2] outputs = { };
	two_outputs(outputs[..]);
	display::OutputChange[2] changes = { };
	changes[1] = { .output_id = "HDMI-1", .enabled = false };
	// A 1x1 mode at scale 4 has no logical pixels at all: refused, not accepted with a 0x0 size.
	changes[0] = {
		.output_id = "DP-1",
		.enabled = true,
		.mode = { .width = 1, .height = 1, .refresh = 60000 },
		.scale = maybe::value(4.0)
	};
	test::@error(display::validate_config(outputs[..], { .outputs = changes[..] }), error::INVALID_ARGUMENT);
	changes[0] = { .output_id = "DP-1", .enabled = true, .mode = fhd60(), .scale = maybe::value(11.0) };
	test::@error(display::validate_config(outputs[..], { .outputs = changes[..] }), error::INVALID_ARGUMENT);
	changes[0] = {
		.output_id = "DP-1",
		.enabled = true,
		.mode = { .width = 100000, .height = 1080, .refresh = 60000 }
	};
	test::@error(display::validate_config(outputs[..], { .outputs = changes[..] }), error::INVALID_ARGUMENT);
	changes[0] = { .output_id = "DP-1", .enabled = true, .mode = fhd60(), .scale = maybe::value(2.0) };
	display::validate_config(outputs[..], { .outputs = changes[..] })!!;
}