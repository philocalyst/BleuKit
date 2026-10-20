<*
 Numbers in JSON: integers written digit by digit, and floats in the shortest
 form that reads back to the same value.

 Floats never depend on the locale: the digits come from C's `%g` in the "C"
 locale that C3 programs run in, and the decimal point is always `.`.
*>
module bleu::json;
import bleu::error;
import std::math;
import std::core::string;

<* Most significant digits a `double` can need to round-trip (IEEE 754 binary64). *>
const int DOUBLE_DIGITS = 17;

<* Most significant digits a `float` can need to round-trip (IEEE 754 binary32). *>
const int FLOAT_DIGITS = 9;

<* Digits of the widest 64-bit integer, including a sign is written separately. *>
const usz INTEGER_DIGITS = 20;

<* `%.Ng` formats, indexed by N - 1, from one to seventeen significant digits. *>
const String[DOUBLE_DIGITS] PRECISION_FORMATS = {
	"%.1g",
	"%.2g",
	"%.3g",
	"%.4g",
	"%.5g",
	"%.6g",
	"%.7g",
	"%.8g",
	"%.9g",
	"%.10g",
	"%.11g",
	"%.12g",
	"%.13g",
	"%.14g",
	"%.15g",
	"%.16g",
	"%.17g",
};

<*
 Write an unsigned integer, with a leading `-` when `negative`. The magnitude
 is passed separately so that the most negative `long` needs no special case.
*>
fn void? JsonWriter.put_integer(&self, bool negative, ulong magnitude)
{
	char[INTEGER_DIGITS] digits;
	usz start = INTEGER_DIGITS;
	do
	{
		start--;
		digits[start] = '0' + (char)(magnitude % 10);
		magnitude /= 10;
	} while (magnitude > 0);
	self.begin_value()!;
	if (negative) self.emit("-")!;
	self.emit((String)digits[start:INTEGER_DIGITS - start])!;
	self.end_value();
}

<* Write a signed integer as a JSON number. *>
fn void? JsonWriter.put_int(&self, long value)
{
	if (value < 0) return self.put_integer(true, (ulong)(-(value + 1)) + 1);
	return self.put_integer(false, (ulong)value);
}

<* Write an unsigned integer as a JSON number. *>
fn void? JsonWriter.put_uint(&self, ulong value) => self.put_integer(false, value);

<*
 The shortest `%g` text of `value` that parses back to the same number, using
 at most `max_digits` significant digits. `single` compares as `float`.

 The result lives in temporary memory; the caller must be inside a `@pool`.
*>
fn String shortest_text(double value, bool single, int max_digits) @inline
{
	String text = "";
	for (int digits = 0; digits < max_digits; digits++)
	{
		text = string::tformat(PRECISION_FORMATS[digits], value);
		if (try back = text.to_double())
		{
			if (single ? (float)back == (float)value : back == value) return text;
		}
	}
	return text;
}

<*
 Write a double as a JSON number in shortest round-trip form. NaN and the
 infinities have no JSON form and are written as `null`, never as an error:
 a snapshot with an unknown measurement must still serialise.
*>
fn void? JsonWriter.put_double(&self, double value)
{
	if (math::is_nan(value) || math::is_inf(value)) return self.put_null();
	@pool()
	{
		return self.put_token(shortest_text(value, false, DOUBLE_DIGITS));
	};
}

<*
 Write a float as a JSON number in shortest form that reads back as the same
 `float`, so `0.7f` is written `0.7`, not `0.699999988079071`. NaN and the
 infinities are written as `null`.
*>
fn void? JsonWriter.put_float(&self, float value)
{
	if (math::is_nan(value) || math::is_inf(value)) return self.put_null();
	@pool()
	{
		return self.put_token(shortest_text((double)value, true, FLOAT_DIGITS));
	};
}