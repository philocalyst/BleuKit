module bleu::json;
import bleu::error;

fn void declared_names_become_camel_case() @test
{
	char[NAME_CAPACITY] scratch;
	assert(camel_case("time_to_empty", scratch[..])!! == "timeToEmpty");
	assert(camel_case("plain", scratch[..])!! == "plain");
	assert(camel_case("_leading", scratch[..])!! == "_leading");
	assert(camel_case("trailing_", scratch[..])!! == "trailing_");
	assert(camel_case("a__b", scratch[..])!! == "aB");
	assert(camel_case("x1_2", scratch[..])!! == "x12");
	assert(camel_case("_", scratch[..])!! == "_");
}

fn void camel_case_refuses_names_longer_than_the_scratch() @test
{
	char[4] small;
	if (catch camel_case("too_long", small[..]))
	{
		assert(error::last().status == error::Status.OUT_OF_RANGE);
	}
	else
	{
		assert(false);
	}
}

fn void enum_values_are_lower_or_upper_snake() @test
{
	char[NAME_CAPACITY] scratch;
	assert(enum_text("NOT_CHARGING", LOWER_SNAKE, scratch[..])!! == "not_charging");
	assert(enum_text("NOT_CHARGING", UPPER_SNAKE, scratch[..])!! == "NOT_CHARGING");
	assert(enum_text("LEAD_ACID", LOWER_SNAKE, scratch[..])!! == "lead_acid");
}

fn void key_text_keeps_the_declared_name_by_default() @test
{
	char[NAME_CAPACITY] scratch;
	assert(key_text("time_to_empty", AS_DECLARED, scratch[..])!! == "time_to_empty");
	assert(key_text("time_to_empty", CAMEL_CASE, scratch[..])!! == "timeToEmpty");
	Options defaults = { };
	assert(defaults.enum_style == LOWER_SNAKE && defaults.key_style == AS_DECLARED);
}