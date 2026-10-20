// Unit tests for bleu::dbus::value: constructors validate their input, accessors
// see through variants, and dictionaries are searched by key.
module bleu::dbus::value_test;
import bleu::dbus::value, bleu::dbus::testing, bleu::error;

fn void constructors_carry_their_signature() @test
{
	@pool()
	{
		assert(value::u32(7).sig == "u");
		assert(value::boolean(true).sig == "b");
		assert(value::float64(1.5).sig == "d");
		Value text = value::str(tmem, "x")!!;
		assert(text.sig == "s" && text.text == "x");
		Value path = value::path(tmem, "/a/b")!!;
		assert(path.sig == "o");
		Value variant = value::variant(tmem, value::i64(-4));
		assert(variant.sig == "v" && variant.unwrap().sig == "x");
	};
}

fn void constructors_refuse_invalid_text() @test
{
	@pool()
	{
		testing::@expect_fault(value::str(tmem, "a\0b"), error::INVALID_ARGUMENT);
		testing::@expect_fault(value::path(tmem, "not/a/path"), error::INVALID_ARGUMENT);
		testing::@expect_fault(value::sig(tmem, "aa"), error::INVALID_ARGUMENT);
	};
}

fn void containers_check_their_element_types() @test
{
	@pool()
	{
		Value[] words = { value::str(tmem, "a")!!, value::str(tmem, "b")!! };
		Value list    = value::array(tmem, "s", words)!!;
		assert(list.sig == "as" && list.count() == 2);
		assert(list.at(1)!!.as_string()!! == "b");
		testing::@expect_fault(value::array(tmem, "u", words), error::INVALID_ARGUMENT);
		Value[] numbers = { value::u32(1) };
		testing::@expect_fault(value::array(tmem, "s", numbers), error::INVALID_ARGUMENT);
	};
}

fn void structs_and_dict_entries() @test
{
	@pool()
	{
		Value[] fields = { value::u32(1), value::str(tmem, "two")!! };
		Value pair     = value::structure(tmem, fields)!!;
		assert(pair.sig == "(us)");
		assert(pair.at(1)!!.as_string()!! == "two");
		Value entry = value::dict_entry(tmem, value::str(tmem, "k")!!, value::u32(3))!!;
		assert(entry.sig == "{su}");
		testing::@expect_fault(
			value::dict_entry(tmem, value::variant(tmem, value::u32(1)), value::u32(1)),
			error::INVALID_ARGUMENT
		);
	};
}

fn void accessors_refuse_the_wrong_kind() @test
{
	testing::@expect_fault(value::u32(7).as_string(), TYPE_MISMATCH);
	testing::@expect_fault(value::str(tmem, "x")!!.as_u32(), TYPE_MISMATCH);
	assert(value::i32(-9).as_i32()!! == -9);
	assert(value::u16(65535).as_u16()!! == 65535);
	assert(value::i16(-2).as_i16()!! == -2);
	assert(value::byte_value('z').as_byte()!! == 'z');
	assert(value::unix_fd(3).as_unix_fd()!! == 3);
	assert(value::u64(1UL << 40).as_u64()!! == 1UL << 40);
	assert(value::i64(-1L << 40).as_i64()!! == -1L << 40);
	assert(value::boolean(true).as_bool()!!);
}

fn void dictionary_lookup_sees_through_variants() @test
{
	@pool()
	{
		Value name = value::variant(tmem, value::str(tmem, "bleu")!!);
		Value[] entries = {
			value::dict_entry(tmem, value::str(tmem, "Name")!!, name)!!,
		};
		Value dict = value::array(tmem, "{sv}", entries)!!;
		assert(dict.dict_get("Name")!!.as_string()!! == "bleu");
		testing::@expect_fault(dict.dict_get("Missing"), NOT_FOUND);
		testing::@expect_fault(value::u32(1).dict_get("Name"), NOT_FOUND);
	};
}