module bleu::json::read;
import bleu::error;
import std::encoding::json;
import std::collections::maybe;
import std::collections::object;

<* The text of the most recent error on this thread, as a String. *>
fn String last_message() => (String)error::last().text[0:error::last().len];

<* Parse a literal document; the test is wrong if it is not valid. *>
fn Object* parsed(String text)
{
	return json::tparse(text, json::JsonFlavor.JSON)!!;
}

fn void typed_getters_read_their_type() @test
{
	Object* doc = parsed(`{"s":"x","b":true,"d":1.5,"n":-3,"o":{},"a":[]}`);
	assert(get_string(doc, "s")!! == "x");
	assert(get_bool(doc, "b")!! == true);
	assert(get_double(doc, "d")!! == 1.5);
	assert(get_int(doc, "n")!! == -3);
	assert(get_double(doc, "n")!! == -3.0);
	get_object(doc, "o")!!;
	get_array(doc, "a")!!;
}

fn void integral_floats_are_integers_and_fractions_are_not() @test
{
	Object* doc = parsed(`{"step":3.0,"frac":3.5,"huge":1e30,"text":"4"}`);
	assert(get_int(doc, "step")!! == 3);
	if (catch get_int(doc, "frac"))
	{
		assert(error::last().status == error::Status.INVALID_ARGUMENT);
		assert(last_message() == "member 'frac' is not an integer");
	}
	else
	{
		assert(false);
	}
	if (catch get_int(doc, "huge"))
	{
		assert(error::last().status == error::Status.OUT_OF_RANGE);
	}
	else
	{
		assert(false);
	}
	if (catch get_int(doc, "text"))
	{
		assert(last_message() == "member 'text' is not a number");
	}
	else
	{
		assert(false);
	}
}

fn void missing_null_and_wrong_types_name_the_key() @test
{
	Object* doc = parsed(`{"nil":null}`);
	if (catch get_string(doc, "absent"))
	{
		assert(last_message() == "member 'absent' is missing or null");
	}
	else
	{
		assert(false);
	}
	if (catch get_string(doc, "nil"))
	{
		assert(last_message() == "member 'nil' is missing or null");
	}
	else
	{
		assert(false);
	}
}

fn void a_non_object_parent_is_an_error_not_a_crash() @test
{
	Object* array = parsed("[1,2]");
	if (catch get_string(array, "x"))
	{
		assert(error::last().status == error::Status.INVALID_ARGUMENT);
		assert(last_message() == "member 'x' is looked up in a value that is not an object");
	}
	else
	{
		assert(false);
	}
	Params none = { };
	assert(none.int_or("step", 9)!! == 9);
	assert(!none.optional_string("password")!!.has_value);
	if (catch none.string("ssid"))
	{
		assert(last_message() == "member 'ssid' is missing or null");
	}
	else
	{
		assert(false);
	}
}

fn void params_defaults_and_optionals() @test
{
	Params p = { .object = parsed(`{"step":2,"password":"pw","flag":false}`) };
	assert(p.int_or("step", 1)!! == 2);
	assert(p.int_or("absent", 1)!! == 1);
	Maybe{String} pw = p.optional_string("password")!!;
	assert(pw.has_value && pw.value == "pw");
	assert(!p.optional_string("absent")!!.has_value);
	assert(p.boolean("flag")!! == false);
	assert(p.number("step")!! == 2.0);
	if (catch p.optional_string("step"))
	{
		assert(last_message() == "member 'step' is not a string");
	}
	else
	{
		assert(false);
	}
}