module bleu::windows_window_ids_test;
import bleu::error, bleu::windows::window_ids;

fn void decimal_window_numbers_are_read() @test
{
	assert(window_ids::number_of("1234")!! == 1234);
	assert(window_ids::number_of("0")!! == 0);
	expect_refused("");
	expect_refused("12a");
	expect_refused("-4");
}

fn void expect_refused(String text) @private
{
	long? value = window_ids::number_of(text);
	if (catch err = value)
	{
		assert(err == error::INVALID_ARGUMENT);
	}
	else
	{
		unreachable("accepted a window id that is not decimal");
	}
}