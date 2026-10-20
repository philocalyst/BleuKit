// Tests for the binary reader: golden comparisons with Python's plistlib, hand
// built files for every marker and every refusal, and a size-bomb limit.
module bleu::plist::binary;
import bleu::error, bleu::plist::value, std::core::test;

// Append `value` as `size` big-endian bytes.
fn void append_be(DString* out, ulong value, usz size) @local
{
	for (usz i = size; i > 0; i--)
	{
		out.append_char((char)((value >> (8 * (i - 1))) & 0xFF));
	}
}

// Serialise `objects` as a bplist00 file with 2-byte references and 2-byte offsets.
// The object at index `top` is the root.
fn String build_bplist(String[] objects, usz top) @local
{
	DString out;
	out.init(tmem);
	out.append_string("bplist00");
	usz[] offsets = alloc::new_array(tmem, usz, objects.len);
	foreach (i, object : objects)
	{
		offsets[i] = (usz)out.len();
		out.append_string(object);
	}
	usz table_offset = (usz)out.len();
	foreach (offset : offsets) append_be(&out, offset, 2);
	for (int i = 0; i < 5; i++) out.append_char(0);
	out.append_char(0);
	out.append_char(2);
	out.append_char(2);
	append_be(&out, objects.len, 8);
	append_be(&out, top, 8);
	append_be(&out, table_offset, 8);
	return out.copy_str(tmem);
}

// `marker` followed by `payload`.
fn String object(String marker, String payload) @local => string::tformat("%s%s", marker, payload);

// A chain of `depth` arrays, each holding a reference to the next, ending in `true`.
fn String[] chain(int depth) @local
{
	String[] objects = alloc::new_array(tmem, String, (sz)depth + 1);
	for (int i = 0; i < depth; i++)
	{
		DString ref;
		ref.init(tmem);
		ref.append_char((char)0xA1);
		append_be(&ref, (ulong)(i + 1), 2);
		objects[i] = ref.copy_str(tmem);
	}
	objects[depth] = "\x09";
	return objects;
}

fn void golden_binary_fixtures_match_plistlib() @test
{
	String sample = $embed("../fixtures/sample.bplist");
	Value root    = parse(tmem, sample)!!;
	test::eq(((String)$embed("../fixtures/sample.bplist.canon")).trim("\n"), value::canonical(tmem, &root));

	String shared = $embed("../fixtures/shared.bplist");
	Value many    = parse(tmem, shared)!!;
	test::eq(((String)$embed("../fixtures/shared.bplist.canon")).trim("\n"), value::canonical(tmem, &many));

	String uid = $embed("../fixtures/uid.bplist");
	Value uids = parse(tmem, uid)!!;
	test::eq(((String)$embed("../fixtures/uid.bplist.canon")).trim("\n"), value::canonical(tmem, &uids));
}

fn void integers_in_every_width() @test
{
	test::eq(
		-5,
		parse(
			tmem,
			build_bplist({ object("\x14", "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFB") }, 0)
		)!!.as_integer()!!
	);
	test::eq(
		5,
		parse(
			tmem,
			build_bplist({ object("\x14", "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05") }, 0)
		)!!.as_integer()!!
	);
	test::eq(-1, parse(tmem, build_bplist({ object("\x13", "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF") }, 0))!!.as_integer()!!);
	test::eq(255, parse(tmem, build_bplist({ object("\x10", "\xFF") }, 0))!!.as_integer()!!);
	test::eq(65535, parse(tmem, build_bplist({ object("\x11", "\xFF\xFF") }, 0))!!.as_integer()!!);
	test::eq(0xFFFFFFFF, parse(tmem, build_bplist({ object("\x12", "\xFF\xFF\xFF\xFF") }, 0))!!.as_integer()!!);
}

fn void integers_too_wide_for_64_bits_are_refused() @test
{
	test::@error(
		parse(
			tmem,
			build_bplist({ object("\x14", "\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00") }, 0)
		),
		error::OUT_OF_RANGE
	);
}

fn void reals_and_dates() @test
{
	test::eq(1.5, parse(tmem, build_bplist({ object("\x22", "\x3F\xC0\x00\x00") }, 0))!!.as_real()!!);
	test::eq(0.25, parse(tmem, build_bplist({ object("\x23", "\x3F\xD0\x00\x00\x00\x00\x00\x00") }, 0))!!.as_real()!!);
	test::eq(0.0, parse(tmem, build_bplist({ object("\x33", "\x00\x00\x00\x00\x00\x00\x00\x00") }, 0))!!.as_date()!!);
	test::@error(parse(tmem, build_bplist({ object("\x21", "\x00\x00") }, 0)), error::PROTOCOL);
	test::@error(parse(tmem, build_bplist({ object("\x30", "\x00\x00\x00\x00\x00\x00\x00\x00") }, 0)), error::PROTOCOL);
}

fn void utf16_strings_use_surrogate_pairs() @test
{
	String emoji = parse(tmem, build_bplist({ object("\x62", "\xD8\x3D\xDE\x00") }, 0))!!.as_string()!!;
	test::eq("\xF0\x9F\x98\x80", emoji);
	test::@error(parse(tmem, build_bplist({ object("\x61", "\xD8\x3D") }, 0)), error::PROTOCOL);
	test::@error(parse(tmem, build_bplist({ object("\x61", "\xDC\x00") }, 0)), error::PROTOCOL);
}

fn void ascii_strings() @test
{
	test::eq("hi", parse(tmem, build_bplist({ object("\x52", "hi") }, 0))!!.as_string()!!);
	test::eq(
		"aaaaaaaaaaaaaaaaaaaa",
		parse(tmem, build_bplist({ object("\x5F", "\x10\x14aaaaaaaaaaaaaaaaaaaa") }, 0))!!.as_string()!!
	);
	test::@error(parse(tmem, build_bplist({ object("\x51", "\xC3") }, 0)), error::PROTOCOL);
}

fn void data_and_uid() @test
{
	test::eq(3, parse(tmem, build_bplist({ object("\x43", "abc") }, 0))!!.as_data()!!.len);
	test::eq(7, parse(tmem, build_bplist({ object("\x80", "\x07") }, 0))!!.as_integer()!!);
	test::eq(256, parse(tmem, build_bplist({ object("\x81", "\x01\x00") }, 0))!!.as_integer()!!);
}

fn void arrays_sets_and_dictionaries() @test
{
	Value set = parse(tmem, build_bplist({ object("\xC1", "\x00\x01"), "\x09" }, 0))!!;
	test::eq(true, set.element(0)!!.as_bool()!!);
	Value dict = parse(tmem, build_bplist({ object("\xD1", "\x00\x01\x00\x02"), "\x51A", "\x09" }, 0))!!;
	test::eq(true, dict.get("A")!!.as_bool()!!);
}

fn void markers_that_are_not_values_are_refused() @test
{
	test::@error(parse(tmem, build_bplist({ "\x00" }, 0)), error::PROTOCOL);
	test::@error(parse(tmem, build_bplist({ "\x0F" }, 0)), error::PROTOCOL);
	test::@error(parse(tmem, build_bplist({ "\x70" }, 0)), error::PROTOCOL);
}

fn void self_and_missing_references_are_refused() @test
{
	test::@error(parse(tmem, build_bplist({ object("\xA1", "\x00\x00") }, 0)), error::PROTOCOL);
	test::@error(parse(tmem, build_bplist({ object("\xA1", "\x00\x09") }, 0)), error::PROTOCOL);
}

fn void dictionary_keys_must_be_strings() @test
{
	test::@error(parse(tmem, build_bplist({ object("\xD1", "\x00\x01\x00\x01"), "\x09" }, 0)), error::PROTOCOL);
}

fn void nesting_is_limited() @test
{
	test::@error(parse(tmem, build_bplist(chain(value::MAX_NESTING + 100), 0)), error::PROTOCOL);
	test::eq(Kind.ARRAY, parse(tmem, build_bplist(chain(10), 0))!!.kind);
}

fn void malformed_trailers_are_refused() @test
{
	String valid = build_bplist({ "\x09" }, 0);
	test::@error(parse(tmem, valid[0:valid.len - 1]), error::PROTOCOL);
	test::@error(parse(tmem, "bplist00"), error::PROTOCOL);
	test::@error(parse(tmem, build_bplist({ "\x09" }, 1)), error::PROTOCOL);
	// One stray byte before the trailer makes the file longer than its trailer says.
	DString extra;
	extra.init(tmem);
	extra.append_string(valid[0:valid.len - 32]);
	extra.append_char(0);
	extra.append_string(valid[valid.len - 32:32]);
	test::@error(parse(tmem, extra.str_view()), error::PROTOCOL);
}

fn void offsets_outside_the_file_are_refused() @test
{
	String valid   = build_bplist({ "\x09" }, 0);
	// The single offset sits two bytes before the 32-byte trailer.
	char[] damaged = alloc::new_array(tmem, char, valid.len);
	mem::copy(damaged.ptr, valid.ptr, valid.len);
	damaged[valid.len - 34] = (char)0xFF;
	damaged[valid.len - 33] = (char)0xFF;
	test::@error(parse(tmem, damaged), error::PROTOCOL);
}

fn void size_bombs_are_bounded() @test
{
	// Each level refers twice to the next, so the tree has 2^22 leaves if it is unfolded.
	String[] objects = alloc::new_array(tmem, String, 23);
	for (int i = 0; i < 22; i++)
	{
		DString ref;
		ref.init(tmem);
		ref.append_char((char)0xA2);
		append_be(&ref, (ulong)(i + 1), 2);
		append_be(&ref, (ulong)(i + 1), 2);
		objects[i] = ref.copy_str(tmem);
	}
	objects[22] = "\x09";
	test::@error(parse(tmem, build_bplist(objects, 0)), error::OUT_OF_RANGE);
}