module bleu::capi::abi_test;
import std::time, bleu::capi, bleu::error;

// The C status numbers are the error::Status ordinals: the wire contract shared with IPC.
fn void status_numbers_follow_the_error_vocabulary() @test
{
	assert((int)capi::CStatus.OK == (int)error::Status.OK);
	assert((int)capi::CStatus.UNSUPPORTED == (int)error::Status.UNSUPPORTED);
	assert((int)capi::CStatus.UNAVAILABLE == (int)error::Status.UNAVAILABLE);
	assert((int)capi::CStatus.PERMISSION_DENIED == (int)error::Status.PERMISSION_DENIED);
	assert((int)capi::CStatus.AUTH_REQUIRED == (int)error::Status.AUTH_REQUIRED);
	assert((int)capi::CStatus.NOT_FOUND == (int)error::Status.NOT_FOUND);
	assert((int)capi::CStatus.INVALID_ARGUMENT == (int)error::Status.INVALID_ARGUMENT);
	assert((int)capi::CStatus.INVALID_STATE == (int)error::Status.INVALID_STATE);
	assert((int)capi::CStatus.BUSY == (int)error::Status.BUSY);
	assert((int)capi::CStatus.TIMEOUT == (int)error::Status.TIMEOUT);
	assert((int)capi::CStatus.CANCELLED == (int)error::Status.CANCELLED);
	assert((int)capi::CStatus.DISCONNECTED == (int)error::Status.DISCONNECTED);
	assert((int)capi::CStatus.PROTOCOL == (int)error::Status.PROTOCOL);
	assert((int)capi::CStatus.BACKEND_FAILURE == (int)error::Status.BACKEND_FAILURE);
	assert((int)capi::CStatus.OUT_OF_RANGE == (int)error::Status.OUT_OF_RANGE);
	assert((int)capi::CStatus.NO_MEMORY == (int)error::Status.NO_MEMORY);
	assert((int)capi::CStatus.UNKNOWN == (int)error::Status.UNKNOWN);
}

fn void timeouts_convert_to_durations() @test
{
	assert(capi::milliseconds(0) == (Duration)0);
	assert(capi::milliseconds(5) == (Duration)5_000);
	assert(capi::wait_duration(-1) == time::FOREVER, "-1 is forever");
	assert(capi::wait_duration(0) == (Duration)0, "0 only polls");
	assert(capi::milliseconds(capi::MAX_MILLISECONDS + 1) == time::FOREVER, "longer than a year is forever");
}

fn void details_copy_truncated_and_terminated() @test
{
	error::Detail detail = { .status = error::Status.NOT_FOUND, .domain = error::Domain.ERRNO, .code = 2, .len = 3 };
	detail.text[0] = 'a';
	detail.text[1] = 'b';
	detail.text[2] = 'c';
	capi::ErrorDetail out;
	capi::fill_detail(&out, &detail);
	assert(out.status == capi::CStatus.NOT_FOUND && out.domain == error::Domain.ERRNO && out.native_code == 2);
	assert(out.message[0] == 'a' && out.message[2] == 'c' && out.message[3] == 0);
}

// Stands for a versioned options struct: size first, then members appended over time.
struct Versioned
{
	uint struct_size;
	uint backend;
}

fn void options_keep_their_defaults_for_older_callers() @test
{
	Versioned current = { };
	Versioned older   = { .struct_size = 4, .backend = 9 }; // `backend` lies beyond the caller's struct_size
	assert(capi::take_options(&current, Versioned::size, &older, older.struct_size) == capi::CStatus.OK);
	assert(current.struct_size == 4 && current.backend == 0, "a member beyond struct_size is not read");
	assert(capi::take_options(&current, Versioned::size, &older, 0) == capi::CStatus.INVALID_ARGUMENT);
}