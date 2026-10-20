module bleu::power::convert_test;
import std::time, bleu::power, bleu::power::convert, bleu::availability, bleu::error;

fn void profile_names_round_trip() @test
{
	assert((convert::profile_name(POWER_SAVER) ?? "") == "power-saver");
	assert((convert::profile_name(BALANCED) ?? "") == "balanced");
	assert((convert::profile_name(PERFORMANCE) ?? "") == "performance");
	assert((convert::profile_from_name("balanced") ?? Profile.UNKNOWN) == BALANCED);
	assert((convert::profile_from_name("performance") ?? Profile.UNKNOWN) == PERFORMANCE);
}

fn void degraded_reasons_map_and_keep_unknown_text() @test
{
	assert(convert::degraded_from_text("") == NONE);
	assert(convert::degraded_from_text("lap-detected") == LAP_DETECTED);
	assert(convert::degraded_from_text("high-operating-temperature") == HIGH_TEMPERATURE);
	assert(convert::degraded_from_text("something-new") == OTHER);
}

fn void can_answers_say_whether_the_action_can_proceed() @test
{
	Availability yes = convert::availability_from_can(
		"yes"
	) ?? availability::no(availability::Reason.BACKEND_STOPPED, "");
	assert(yes.ok());
	Availability challenge = convert::availability_from_can("challenge") ?? availability::YES;
	assert(challenge.reason == availability::Reason.PERMISSION_NEEDED);
	assert(!challenge.ok());
	Availability na = convert::availability_from_can("na") ?? availability::YES;
	assert(na.reason == availability::Reason.HARDWARE_ABSENT);
	Availability no = convert::availability_from_can("no") ?? availability::YES;
	assert(no.reason == availability::Reason.DISABLED_BY_POLICY);
	Availability inhibited = convert::availability_from_can(
		"inhibited"
	) ?? availability::no(availability::Reason.BACKEND_STOPPED, "");
	assert(inhibited.ok());
	Availability blocked = convert::availability_from_can("inhibitor-blocked") ?? availability::YES;
	assert(blocked.reason == availability::Reason.DISABLED_BY_POLICY);
	Availability both = convert::availability_from_can("challenge-inhibitor-blocked") ?? availability::YES;
	assert(both.reason == availability::Reason.PERMISSION_NEEDED);
}

fn void actions_and_inhibitors_name_their_capability() @test
{
	assert(power::action_cap(SUSPEND) == Cap.SUSPEND);
	assert(power::action_cap(LOGOUT) == Cap.LOGOUT);
	assert(power::inhibit_cap(SLEEP_DELAY) == Cap.DELAY_SLEEP_HOOK);
	assert(power::inhibit_cap(SHUTDOWN_BLOCK) == Cap.BLOCK_SHUTDOWN);
	assert(power::inhibit_cap(KEEP_AWAKE_DISPLAY) == Cap.KEEP_AWAKE_DISPLAY);
}

fn void only_refusals_for_good_are_refused_at_open() @test
{
	assert(convert::refused_at_open("na"), "no hardware");
	assert(convert::refused_at_open("no"), "forbidden by configuration");
	assert(!convert::refused_at_open("challenge"), "polkit asks the user");
	assert(!convert::refused_at_open("inhibitor-blocked"), "blocked only for now");
	assert(!convert::refused_at_open("yes"));
}

fn void reconnects_back_off_to_a_ceiling() @test
{
	assert(convert::reconnect_delay(0) == (Duration)1_000_000);
	assert(convert::reconnect_delay(1) == (Duration)2_000_000);
	assert(convert::reconnect_delay(4) == (Duration)16_000_000);
	assert(convert::reconnect_delay(5) == (Duration)30_000_000, "capped at 30 s");
	assert(convert::reconnect_delay(100) == (Duration)30_000_000);
}