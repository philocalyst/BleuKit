module bleu::json;

<* Quote `text` as a JSON string through a fresh writer and return the output. *>
fn String quoted_for_test(DString* out, String text)
{
	out.clear();
	JsonWriter w;
	w.init_dstring(out);
	w.put_string(text)!!;
	return out.str_view();
}

fn void control_characters_and_quotes_are_escaped() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	assert(quoted_for_test(&out, "\"\\\b\f\n\r\t") == `"\"\\\b\f\n\r\t"`);
	assert(quoted_for_test(&out, "\x01\x1f\x7f") == "\"\\u0001\\u001f\x7f\"");
	assert(quoted_for_test(&out, "/plain/") == `"/plain/"`);
}

fn void valid_utf8_is_copied_unchanged() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	// U+00E9, U+20AC, U+1F600, and the boundary code points U+0800, U+FFFD, U+10FFFF.
	assert(quoted_for_test(&out, "\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80") == "\"\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80\"");
	assert(quoted_for_test(
		&out,
		"\xE0\xA0\x80\xEF\xBF\xBD\xF4\x8F\xBF\xBF"
	) == "\"\xE0\xA0\x80\xEF\xBF\xBD\xF4\x8F\xBF\xBF\"");
}

fn void invalid_utf8_becomes_one_replacement_per_maximal_subpart() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	// A lone continuation byte.
	assert(quoted_for_test(&out, "\x80") == "\"\xEF\xBF\xBD\"");
	// A truncated three-byte sequence is one maximal subpart.
	assert(quoted_for_test(&out, "a\xE2\x82z") == "\"a\xEF\xBF\xBD" "z\"");
	// Overlong encodings of '/' (C0 AF) and of U+0000 (E0 80 80): every byte is invalid.
	assert(quoted_for_test(&out, "\xC0\xAF") == "\"\xEF\xBF\xBD\xEF\xBF\xBD\"");
	assert(quoted_for_test(&out, "\xE0\x80\x80") == "\"\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF\xBD\"");
	// UTF-16 surrogates are not scalar values.
	assert(quoted_for_test(&out, "\xED\xA0\x80") == "\"\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF\xBD\"");
	// Above U+10FFFF.
	assert(quoted_for_test(&out, "\xF4\x90\x80\x80") == "\"\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF\xBD\"");
	// A lead byte that never starts a sequence.
	assert(quoted_for_test(&out, "\xFF\xFE") == "\"\xEF\xBF\xBD\xEF\xBF\xBD\"");
	// Truncated at the end of the text.
	assert(quoted_for_test(&out, "\xF0\x9F\x98") == "\"\xEF\xBF\xBD\"");
}

fn void utf8_unit_reports_lengths() @test
{
	bool valid;
	assert(utf8_unit("A", 0, &valid) == 1 && valid);
	assert(utf8_unit("\xC3\xA9", 0, &valid) == 2 && valid);
	assert(utf8_unit("\xF0\x9F\x98\x80", 0, &valid) == 4 && valid);
	assert(utf8_unit("\xE2\x82", 0, &valid) == 2 && !valid);
	assert(utf8_unit("\xE0\x80", 0, &valid) == 1 && !valid);
	assert(utf8_unit("\xED\xA0", 0, &valid) == 1 && !valid);
}

fn void integers_are_written_exactly() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	JsonWriter w;
	w.init_dstring(&out);
	w.begin_array()!!;
	w.put_int(0)!!;
	w.put_int(-1)!!;
	w.put_int(long::min)!!;
	w.put_int(long::max)!!;
	w.put_uint(ulong::max)!!;
	w.end_array()!!;
	assert(out.str_view() == "[0,-1,-9223372036854775808,9223372036854775807,18446744073709551615]");
}

fn void doubles_use_the_shortest_round_trip_form() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	JsonWriter w;
	w.init_dstring(&out);
	w.begin_array()!!;
	w.put_double(0.1)!!;
	w.put_double(1.0)!!;
	w.put_double(-0.0)!!;
	w.put_double(123456.789)!!;
	w.put_double(1e21)!!;
	w.put_double(5e-324)!!;
	w.put_double(0.30000000000000004)!!;
	w.end_array()!!;
	assert(out.str_view() == "[0.1,1,-0,123456.789,1e+21,5e-324,0.30000000000000004]");
}

fn void non_finite_doubles_are_null() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	JsonWriter w;
	w.init_dstring(&out);
	w.begin_array()!!;
	w.put_double(0.0 / 0.0)!!;
	w.put_double(1.0 / 0.0)!!;
	w.put_double(-1.0 / 0.0)!!;
	w.put_float(0.0f / 0.0f)!!;
	w.end_array()!!;
	assert(out.str_view() == "[null,null,null,null]");
}

fn void floats_are_shortest_for_single_precision() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	JsonWriter w;
	w.init_dstring(&out);
	w.begin_array()!!;
	w.put_float(0.7f)!!;
	w.put_float(0.1f)!!;
	w.put_float(3.14159f)!!;
	w.put_float(16777216.0f)!!;
	w.end_array()!!;
	assert(out.str_view() == "[0.7,0.1,3.14159,16777216]");
}