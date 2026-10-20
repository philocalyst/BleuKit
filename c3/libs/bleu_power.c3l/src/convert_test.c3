module bleu::power::convert_test;
import bleu::power, bleu::power::convert, bleu::availability, bleu::error;

// The fault a refused conversion returns, or OK-equivalent UNKNOWN when it succeeds.
fn fault fault_of_name(Profile profile)
{
	if (catch err = convert::profile_name(profile)) return err;
	return error::UNSUPPORTED;
}

fn fault fault_of_profile(String name)
{
	if (catch err = convert::profile_from_name(name)) return err;
	return error::UNSUPPORTED;
}

fn fault fault_of_can(String answer)
{
	if (catch err = convert::availability_from_can(answer)) return err;
	return error::UNSUPPORTED;
}

fn void profile_names_round_trip() @test
{
	assert(convert::profile_name(POWER_SAVER)! == "power-saver");
	assert(convert::profile_name(BALANCED)! == "balanced");
	assert(convert::profile_name(PERFORMANCE)! == "performance");
	assert(convert::profile_from_name("balanced")! == BALANCED);
	assert(convert::profile_from_name("performance")! == PERFORMANCE);
	assert(fault_of_name(UNKNOWN) == error::INVALID_ARGUMENT);
	assert(fault_of_profile("turbo") == NOT_FOUND);
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
	assert(convert::availability_from_can("yes")!.ok());
	assert(convert::availability_from_can("challenge")!.reason == availability::Reason.PERMISSION_NEEDED);
	assert(!convert::availability_from_can("challenge")!.ok());
	assert(convert::availability_from_can("na")!.reason == availability::Reason.HARDWARE_ABSENT);
	assert(convert::availability_from_can("no")!.reason == availability::Reason.DISABLED_BY_POLICY);
	assert(convert::availability_from_can("inhibited")!.ok());
	assert(convert::availability_from_can("inhibitor-blocked")!.reason == availability::Reason.DISABLED_BY_POLICY);
	assert(convert::availability_from_can("challenge-inhibitor-blocked")!.reason == availability::Reason.PERMISSION_NEEDED);
	assert(fault_of_can("maybe") == error::PROTOCOL);
}

fn void actions_and_inhibitors_name_their_capability() @test
{
	assert(action_cap(SUSPEND) == Cap.SUSPEND);
	assert(action_cap(LOGOUT) == Cap.LOGOUT);
	assert(inhibit_cap(SLEEP_DELAY) == Cap.DELAY_SLEEP_HOOK);
	assert(inhibit_cap(SHUTDOWN_BLOCK) == Cap.BLOCK_SHUTDOWN);
	assert(inhibit_cap(KEEP_AWAKE_DISPLAY) == Cap.KEEP_AWAKE_DISPLAY);
}
