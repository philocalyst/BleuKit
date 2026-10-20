module bleu::notify::rules_test;
import std::collections::maybe, std::time, bleu::notify, bleu::notify::rules;

fn void expiry_follows_the_sender_and_urgency() @test
{
	notify::Policy policy = notify::DEFAULT_POLICY;
	// -1: the server default for the urgency.
	assert(rules::timeout_for(notify::Urgency.NORMAL, -1, &policy).value == policy.normal_timeout);
	assert(rules::timeout_for(notify::Urgency.LOW, -1, &policy).value == policy.low_timeout);
	// A positive value is milliseconds.
	assert(rules::timeout_for(notify::Urgency.NORMAL, 250, &policy).value == time::ms(250));
	// 0: never.
	assert(!rules::timeout_for(notify::Urgency.NORMAL, 0, &policy).has_value);
}

fn void critical_never_expires() @test
{
	notify::Policy policy = notify::DEFAULT_POLICY;
	assert(!rules::timeout_for(notify::Urgency.CRITICAL, -1, &policy).has_value);
	assert(!rules::timeout_for(notify::Urgency.CRITICAL, 5000, &policy).has_value);
}

fn void a_zero_default_means_never() @test
{
	notify::Policy policy = notify::DEFAULT_POLICY;
	policy.normal_timeout = time::DURATION_ZERO;
	assert(!rules::timeout_for(notify::Urgency.NORMAL, -1, &policy).has_value);
}

fn void ids_skip_zero_and_wrap() @test
{
	assert(rules::next_id(1) == 2);
	assert(rules::next_id((notify::NoteId)0xFFFF_FFFF) == 1);
}

fn void do_not_disturb_holds_only_the_lesser_urgencies() @test
{
	assert(rules::held_by_dnd(true, notify::Urgency.NORMAL));
	assert(rules::held_by_dnd(true, notify::Urgency.LOW));
	assert(!rules::held_by_dnd(true, notify::Urgency.CRITICAL));
	assert(!rules::held_by_dnd(false, notify::Urgency.NORMAL));
}
