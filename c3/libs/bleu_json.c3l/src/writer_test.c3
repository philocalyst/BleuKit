module bleu::json;
import bleu::error;

fn void compact_document_golden() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	JsonWriter w;
	w.init_dstring(&out);
	w.begin_object()!!;
	w.key("a")!!;
	w.put_int(1)!!;
	w.key("b")!!;
	w.begin_array()!!;
	w.put_bool(true)!!;
	w.put_null()!!;
	w.put_string("x")!!;
	w.end_array()!!;
	w.key("empty")!!;
	w.begin_object()!!;
	w.end_object()!!;
	w.end_object()!!;
	w.finish()!!;
	assert(out.str_view() == `{"a":1,"b":[true,null,"x"],"empty":{}}`);
	assert(w.is_complete());
}

fn void indented_document_golden() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	JsonWriter w;
	w.init_dstring(&out, 2);
	w.begin_object()!!;
	w.key("list")!!;
	w.begin_array()!!;
	w.put_uint(7)!!;
	w.end_array()!!;
	w.key("none")!!;
	w.begin_array()!!;
	w.end_array()!!;
	w.end_object()!!;
	w.finish()!!;
	assert(out.str_view() == "{\n  \"list\": [\n    7\n  ],\n  \"none\": []\n}");
}

fn void buffer_writer_writes_and_refuses_overflow() @test
{
	char[12] storage;
	JsonWriter w;
	w.init_buffer(storage[..]);
	w.begin_array()!!;
	w.put_int(-12)!!;
	w.end_array()!!;
	w.finish()!!;
	assert(w.written() == "[-12]");
	// A second writer on the same storage refuses a value that does not fit.
	JsonWriter small;
	small.init_buffer(storage[0:4]);
	small.begin_array()!!;
	small.put_int(1)!!;
	@expect_fault(small.put_int(22), error::OUT_OF_RANGE);
	assert(error::last().status == error::Status.OUT_OF_RANGE);
	// The overflow poisons the writer: every later call is refused too.
	@expect_fault(small.end_array(), error::INVALID_STATE);
}

<*
 Assert that `call` fails with `expected`. The call is a macro argument, so
 its result is never passed as an optional parameter.
*>
macro @expect_fault(#call, expected)
{
	if (catch err = #call)
	{
		assert(err == expected);
	}
	else
	{
		assert(false);
	}
}

fn void restart_keeps_earlier_documents() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	JsonWriter w;
	w.init_dstring(&out);
	w.put_int(1)!!;
	w.restart()!!;
	w.begin_array()!!;
	w.end_array()!!;
	w.restart()!!;
	w.put_string("z")!!;
	assert(out.str_view() == "1[]\"z\"");
}

fn void nothing_is_written_when_a_call_is_refused() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	JsonWriter w;
	w.init_dstring(&out);
	w.begin_object()!!;
	@expect_fault(w.put_int(1), error::INVALID_STATE);
	assert(out.str_view() == "{");
	@expect_fault(w.end_array(), error::INVALID_STATE);
	assert(out.str_view() == "{");
	w.key("k")!!;
	w.put_int(1)!!;
	w.end_object()!!;
	w.finish()!!;
	assert(out.str_view() == `{"k":1}`);
}

<*
 Every misuse the state machine refuses, one case each. Each case starts from a
 fresh writer and must fail with INVALID_STATE, leaving the output unchanged.
*>
fn void misuse_is_refused_with_invalid_state() @test
{
	DString out;
	out.init(mem);
	defer out.free();

	// A key outside an object.
	JsonWriter w;
	w.init_dstring(&out);
	@expect_fault(w.key("k"), error::INVALID_STATE);
	w.begin_array()!!;
	@expect_fault(w.key("k"), error::INVALID_STATE);
	w.end_array()!!;
	w.finish()!!;
	out.clear();

	// A value inside an object with no key before it.
	w.init_dstring(&out);
	w.begin_object()!!;
	@expect_fault(w.put_int(1), error::INVALID_STATE);
	@expect_fault(w.begin_array(), error::INVALID_STATE);
	out.clear();

	// Two keys in a row.
	w.init_dstring(&out);
	w.begin_object()!!;
	w.key("a")!!;
	@expect_fault(w.key("b"), error::INVALID_STATE);
	out.clear();

	// Closing the wrong kind of container.
	w.init_dstring(&out);
	w.begin_object()!!;
	@expect_fault(w.end_array(), error::INVALID_STATE);
	w.end_object()!!;
	out.clear();
	w.init_dstring(&out);
	w.begin_array()!!;
	@expect_fault(w.end_object(), error::INVALID_STATE);
	w.end_array()!!;
	out.clear();

	// Closing an object while a key still waits for its value.
	w.init_dstring(&out);
	w.begin_object()!!;
	w.key("a")!!;
	@expect_fault(w.end_object(), error::INVALID_STATE);
	out.clear();

	// Closing when nothing is open.
	w.init_dstring(&out);
	@expect_fault(w.end_array(), error::INVALID_STATE);
	out.clear();

	// A second top-level value.
	w.init_dstring(&out);
	w.put_int(1)!!;
	@expect_fault(w.put_int(2), error::INVALID_STATE);
	@expect_fault(w.begin_object(), error::INVALID_STATE);
	assert(out.str_view() == "1");
	out.clear();

	// Finishing with a container open, or with no value at all.
	w.init_dstring(&out);
	w.begin_array()!!;
	@expect_fault(w.finish(), error::INVALID_STATE);
	@expect_fault(w.restart(), error::INVALID_STATE);
	out.clear();
	w.init_dstring(&out);
	@expect_fault(w.finish(), error::INVALID_STATE);
	assert(!w.is_complete());
	out.clear();

	// Starting a document in a fresh writer after a key was refused leaves it usable.
	w.init_dstring(&out);
	w.put_string("ok")!!;
	w.finish()!!;
	assert(out.str_view() == `"ok"`);
}

fn void nesting_beyond_the_bound_is_refused() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	JsonWriter w;
	w.init_dstring(&out);
	for (usz i = 0; i < MAX_DEPTH; i++)
	{
		w.begin_array()!!;
	}
	@expect_fault(w.begin_array(), error::OUT_OF_RANGE);
	for (usz i = 0; i < MAX_DEPTH; i++)
	{
		w.end_array()!!;
	}
	w.finish()!!;
}

fn void raw_fragments_are_validated_and_positioned() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	JsonWriter w;
	w.init_dstring(&out);
	w.begin_object()!!;
	w.key("data")!!;
	w.put_raw(` {"x": [1, 2]} `)!!;
	w.key("bad")!!;
	@expect_fault(w.put_raw("{"), error::INVALID_ARGUMENT);
	@expect_fault(w.put_raw("1 2"), error::INVALID_ARGUMENT);
	@expect_fault(w.put_raw(""), error::INVALID_ARGUMENT);
	w.put_raw("null")!!;
	w.end_object()!!;
	w.finish()!!;
	assert(out.str_view() == `{"data":{"x": [1, 2]},"bad":null}`);
}
