// Unit tests for the message decoding and the application message allocator.
// Pure logic: no Win32 import, so these run on every host.
module bleu::win::message_codes;
import bleu::error;

fn void hotkey_lparam_splits_modifiers_and_key() @test
{
	// WM_HOTKEY lParam for Ctrl+Shift+A: MOD_CONTROL | MOD_SHIFT (0x0006) low, VK_A (0x41) high.
	iptr packed = (iptr)0x00410006;
	assert(low_word(packed) == 0x0006);
	assert(high_word(packed) == 0x0041);
}

fn void hotkey_lparam_keeps_all_sixteen_bits() @test
{
	iptr packed = (iptr)0x9abc0008;
	assert(low_word(packed) == 0x0008);
	assert(high_word(packed) == 0x9abc);
}

fn void hotkey_lparam_ignores_bits_above_thirty_two() @test
{
	iptr packed = (iptr)(ulong)0x19abc0008;
	assert(low_word(packed) == 0x0008);
	assert(high_word(packed) == 0x9abc);
}

fn void custom_messages_start_above_wake() @test
{
	CustomMessages ids = { .next = FIRST_CUSTOM_MESSAGE };
	uint first         = ids.allocate()!!;
	uint second        = ids.allocate()!!;
	assert(first == 0x8002);
	assert(second == 0x8003);
	assert(first != WM_WAKE && first != WM_APP);
}

fn void custom_messages_own_only_what_was_handed_out() @test
{
	CustomMessages ids = { .next = FIRST_CUSTOM_MESSAGE };
	uint first         = ids.allocate()!!;
	assert(ids.owns(first));
	assert(!ids.owns(first + 1));
	assert(!ids.owns(WM_WAKE));
	assert(!ids.owns(WM_APP));
	assert(!ids.owns(0xc000));
}

fn void named_messages_are_c000_through_ffff() @test
{
	assert(!is_named_message(LAST_CUSTOM_MESSAGE));
	assert(!is_named_message(0));
	assert(is_named_message(FIRST_NAMED_MESSAGE));
	assert(is_named_message(LAST_NAMED_MESSAGE));
	assert(!is_named_message(0x10000));
	assert(LAST_CUSTOM_MESSAGE < FIRST_NAMED_MESSAGE);
}

fn void custom_messages_run_out_at_the_end_of_the_range() @test
{
	CustomMessages ids = { .next = LAST_CUSTOM_MESSAGE };
	assert(ids.allocate()!! == LAST_CUSTOM_MESSAGE);
	if (catch e = ids.allocate())
	{
		assert(e == CAPACITY_EXCEEDED);
		return;
	}
	unreachable("a message id past 0xBFFF was handed out");
}