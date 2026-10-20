// Reader and Writer behaviour on the golden vectors, and rejection of malformed
// or misused input. Every rejection named here is a rule from the specification.
module bleu::dbus::marshal_reader_test;
import bleu::dbus::marshal, bleu::dbus::value, bleu::dbus::testing, bleu::error;

fn void reads_golden_strings() @test
{
	@pool()
	{
		Reader r;
		r.init(testing::from_hex("03 00 00 00 66 6f 6f 00 01 00 00 00 2b 00 00 00 03 00 00 00 62 61 72 00"), "sss")!!;
		assert(r.read_string()!! == "foo");
		assert(r.read_string()!! == "+");
		assert(r.read_string()!! == "bar");
		r.finish()!!;
	};
}

fn void reads_a_dictionary_into_values() @test
{
	@pool()
	{
		String data = testing::from_hex(
			"60 00 00 00 00 00 00 00 04 00 00 00 4e 61 6d 65 00 01 73 00 04 00 00 00 62 6c 65 75 00 00 00 00 05 00 00 00 43 6f 75 6e 74 00 01 75 00 00 00 00 07 00 00 00 00 00 00 00 06 00 00 00 4e 65 73 74 65 64 00 05 61 7b 73 76 7d 00 00 00 18 00 00 00 01 00 00 00 6b 00 01 76 00 01 64 00 00 00 00 00 00 00 00 00 00 00 f8 3f"
		);
		Reader r;
		r.init(data, "a{sv}")!!;
		Value dict = r.read_value(tmem)!!;
		r.finish()!!;
		assert(dict.count() == 3);
		assert(dict.dict_get("Name")!!.as_string()!! == "bleu");
		assert(dict.dict_get("Count")!!.as_u32()!! == 7);
		assert(dict.dict_get("Nested")!!.dict_get("k")!!.as_f64()!! == 1.5);
		testing::@expect_fault(dict.dict_get("Missing"), NOT_FOUND);
	};
}

fn void round_trips_golden_values_back_to_the_same_bytes() @test
{
	@pool()
	{
		String data = testing::from_hex(
			"18 00 00 00 00 00 00 00 01 01 73 00 01 00 00 00 78 00 00 00 00 00 00 00 02 01 75 00 09 00 00 00"
		);
		Reader r;
		r.init(data, "a(yv)")!!;
		Value list = r.read_value(tmem)!!;
		Writer w;
		w.init(tmem, "a(yv)")!!;
		w.append_value(list)!!;
		w.finish()!!;
		testing::expect_bytes(
			w.bytes(),
			"18 00 00 00 00 00 00 00 01 01 73 00 01 00 00 00 78 00 00 00 00 00 00 00 02 01 75 00 09 00 00 00"
		);
		assert(list.at(1)!!.at(1)!!.as_u32()!! == 9);
	};
}

fn void reads_big_endian_array_as_in_the_specification() @test
{
	@pool()
	{
		Reader r;
		r.init(testing::from_hex("00 00 00 08 00 00 00 00 00 00 00 00 00 00 00 05"), "ax", true)!!;
		r.begin_array()!!;
		assert(r.has_more());
		assert(r.read_i64()!! == 5);
		assert(!r.has_more());
		r.end_array()!!;
		r.finish()!!;
	};
}

fn void reads_variants() @test
{
	@pool()
	{
		Reader r;
		r.init(testing::from_hex("01 74 00 00 00 00 00 00 05 00 00 00 00 00 00 00"), "v")!!;
		Value v = r.read_value(tmem)!!;
		r.finish()!!;
		assert(v.kind == VARIANT);
		assert(v.as_u64()!! == 5);
	};
}

fn void rejects_malformed_input() @test
{
	@pool()
	{
		Reader r;
		r.init(testing::from_hex("02 00 00 00"), "b")!!;
		testing::@expect_fault(r.read_bool(), error::PROTOCOL);
	};
	@pool()
	{
		Reader r;
		r.init(testing::from_hex("01 01 00 00 fe ff ff ff"), "(yi)")!!;
		r.begin_struct()!!;
		assert(r.read_byte()!! == 1);
		testing::@expect_fault(r.read_i32(), error::PROTOCOL);
	};
	@pool()
	{
		Reader r;
		r.init(testing::from_hex("ff 00 00 00 61 00"), "s")!!;
		testing::@expect_fault(r.read_string(), error::PROTOCOL);
	};
	@pool()
	{
		Reader r;
		r.init(testing::from_hex("01 00 00 00 61 62"), "s")!!;
		testing::@expect_fault(r.read_string(), error::PROTOCOL);
	};
	@pool()
	{
		Reader r;
		r.init(testing::from_hex("01 00 00 00 ff 00"), "s")!!;
		testing::@expect_fault(r.read_string(), error::PROTOCOL);
	};
	@pool()
	{
		Reader r;
		r.init(testing::from_hex("01 00 00 04 00"), "ay")!!;
		testing::@expect_fault(r.begin_array(), error::PROTOCOL);
	};
	@pool()
	{
		Reader r;
		r.init(testing::from_hex("0a 00 00 00 01 02"), "ay")!!;
		testing::@expect_fault(r.begin_array(), error::PROTOCOL);
	};
	@pool()
	{
		Reader r;
		r.init(testing::from_hex("01 00"), "u")!!;
		testing::@expect_fault(r.read_u32(), error::PROTOCOL);
	};
	@pool()
	{
		Reader r;
		r.init(testing::from_hex("02 2f 2f 00"), "o")!!;
		testing::@expect_fault(r.read_object_path(), error::PROTOCOL);
	};
	@pool()
	{
		Reader r;
		r.init(testing::from_hex("02 28 28 00"), "g")!!;
		testing::@expect_fault(r.read_signature(), error::PROTOCOL);
	};
	@pool()
	{
		Reader r;
		r.init(testing::from_hex("02 69 69 00"), "v")!!;
		testing::@expect_fault(r.begin_variant(), error::PROTOCOL);
	};
	@pool()
	{
		Reader r;
		r.init(testing::from_hex("01 02"), "y")!!;
		assert(r.read_byte()!! == 1);
		testing::@expect_fault(r.finish(), error::PROTOCOL);
	};
}

fn void reports_misuse_of_the_api() @test
{
	@pool()
	{
		Reader r;
		r.init(testing::from_hex("01 00 00 00"), "u")!!;
		testing::@expect_fault(r.read_string(), error::INVALID_ARGUMENT);
		testing::@expect_fault(r.finish(), error::INVALID_STATE);
		assert(r.read_u32()!! == 1);
		testing::@expect_fault(r.read_u32(), error::INVALID_STATE);
	};
}

fn void writer_refuses_values_that_break_the_signature() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "s")!!;
		testing::@expect_fault(w.append_u32(1), error::INVALID_ARGUMENT);
		assert(w.size() == 0);
		testing::@expect_fault(w.append_string("\xff"), error::INVALID_ARGUMENT);
		testing::@expect_fault(w.append_object_path("a"), error::INVALID_ARGUMENT);
		testing::@expect_fault(w.append_signature("(("), error::INVALID_ARGUMENT);
		assert(w.size() == 0);
		w.append_string("ok")!!;
		testing::@expect_fault(w.append_string("again"), error::INVALID_STATE);
		w.finish()!!;
	};
	@pool()
	{
		Writer w;
		w.init(tmem, "ss")!!;
		w.append_string("one")!!;
		testing::@expect_fault(w.finish(), error::INVALID_STATE);
	};
	@pool()
	{
		Writer w;
		w.init(tmem, "ai")!!;
		w.begin_array("ai")!!;
		testing::@expect_fault(w.end_struct(), error::INVALID_STATE);
		w.append_i32(4)!!;
		w.end_array()!!;
		w.finish()!!;
	};
	@pool()
	{
		Writer w;
		w.init(tmem, "i")!!;
		testing::@expect_fault(w.begin_struct(), error::INVALID_ARGUMENT);
	};
	@pool()
	{
		Writer w;
		w.init(tmem, "i")!!;
		testing::@expect_fault(w.begin_array("ai"), error::INVALID_ARGUMENT);
	};
}