module bleu::iokit::power_codes;

// Power-source state text, from kIOPSPowerSourceStateKey values. Matching is exact.
fn void state_text() @test
{
	assert(classify_state("AC Power") == AC);
	assert(classify_state("Battery Power") == BATTERY);
	assert(classify_state("Off Line") == OFFLINE);
	assert(classify_state("") == UNKNOWN);
	assert(classify_state("ac power") == UNKNOWN);
}

// IOKit power messages (IOMessage.h). Unlisted messages are OTHER and are not acknowledged by the caller.
fn void message_codes() @test
{
	assert(classify_message(0xE0000270) == CAN_SLEEP);
	assert(classify_message(0xE0000280) == WILL_SLEEP);
	assert(classify_message(0xE0000290) == WILL_NOT_SLEEP);
	assert(classify_message(0xE0000320) == WILL_POWER_ON);
	assert(classify_message(0xE0000300) == HAS_POWERED_ON);
	assert(classify_message(0xE0000250) == WILL_POWER_OFF);
	assert(classify_message(0xE0000310) == WILL_RESTART);
	assert(classify_message(0xE0000260) == OTHER);
	assert(classify_message(0) == OTHER);
}
