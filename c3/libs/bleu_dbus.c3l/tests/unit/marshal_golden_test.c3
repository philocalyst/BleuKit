// Golden byte vectors for the marshalling layer.
// 
// Little-endian vectors were produced by python-dbus-next 0.2.3's independent
// marshaller (dbus_next._private.marshaller.Marshaller) for the stated signature
// and value, and re-decoded by its unmarshaller. The big-endian array vector is
// the example in the D-Bus specification, "Marshalling containers".
module bleu::dbus::marshal_golden_test;
import bleu::dbus::marshal, bleu::dbus::testing, bleu::error;

fn void writes_strings() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "sss")!!;
		w.append_string("foo")!!;
		w.append_string("+")!!;
		w.append_string("bar")!!;
		w.finish()!!;
		testing::expect_bytes(w.bytes(), "03 00 00 00 66 6f 6f 00 01 00 00 00 2b 00 00 00 03 00 00 00 62 61 72 00");
	};
}

fn void writes_variant_of_uint64() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "v")!!;
		w.begin_variant("t")!!;
		w.append_u64(5)!!;
		w.end_variant()!!;
		w.finish()!!;
		testing::expect_bytes(w.bytes(), "01 74 00 00 00 00 00 00 05 00 00 00 00 00 00 00");
	};
}

fn void writes_array_of_int64_big_endian_as_in_the_specification() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "ax", true)!!;
		w.begin_array("ax")!!;
		w.append_i64(5)!!;
		w.end_array()!!;
		w.finish()!!;
		testing::expect_bytes(w.bytes(), "00 00 00 08 00 00 00 00 00 00 00 00 00 00 00 05");
	};
}

fn void writes_empty_arrays_with_their_padding() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "ax")!!;
		w.begin_array("ax")!!;
		w.end_array()!!;
		w.finish()!!;
		testing::expect_bytes(w.bytes(), "00 00 00 00 00 00 00 00");
	};
	@pool()
	{
		Writer w;
		w.init(tmem, "ai")!!;
		w.begin_array("ai")!!;
		w.end_array()!!;
		w.finish()!!;
		testing::expect_bytes(w.bytes(), "00 00 00 00");
	};
}

fn void writes_nested_arrays() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "aai")!!;
		w.begin_array("aai")!!;
		w.begin_array("ai")!!;
		w.append_i32(1)!!;
		w.append_i32(2)!!;
		w.end_array()!!;
		w.begin_array("ai")!!;
		w.end_array()!!;
		w.begin_array("ai")!!;
		w.append_i32(3)!!;
		w.end_array()!!;
		w.end_array()!!;
		w.finish()!!;
		testing::expect_bytes(
			w.bytes(),
			"18 00 00 00 08 00 00 00 01 00 00 00 02 00 00 00 00 00 00 00 04 00 00 00 03 00 00 00"
		);
	};
}

fn void writes_scalars_and_text_types() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "b")!!;
		w.append_bool(true)!!;
		w.finish()!!;
		testing::expect_bytes(w.bytes(), "01 00 00 00");
	};
	@pool()
	{
		Writer w;
		w.init(tmem, "d")!!;
		w.append_f64(3.5)!!;
		w.finish()!!;
		testing::expect_bytes(w.bytes(), "00 00 00 00 00 00 0c 40");
	};
	@pool()
	{
		Writer w;
		w.init(tmem, "og")!!;
		w.append_object_path("/a/b")!!;
		w.append_signature("a{sv}")!!;
		w.finish()!!;
		testing::expect_bytes(w.bytes(), "04 00 00 00 2f 61 2f 62 00 05 61 7b 73 76 7d 00");
	};
}

fn void writes_structs_with_eight_byte_alignment() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "(yi)")!!;
		w.begin_struct()!!;
		w.append_byte(1)!!;
		w.append_i32(-2)!!;
		w.end_struct()!!;
		w.finish()!!;
		testing::expect_bytes(w.bytes(), "01 00 00 00 fe ff ff ff");
	};
	@pool()
	{
		Writer w;
		w.init(tmem, "(ynq)")!!;
		w.begin_struct()!!;
		w.append_byte(1)!!;
		w.append_i16(-2)!!;
		w.append_u16(3)!!;
		w.end_struct()!!;
		w.finish()!!;
		testing::expect_bytes(w.bytes(), "01 00 fe ff 03 00");
	};
}

fn void writes_a_string_dictionary_with_variants() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "a{sv}")!!;
		w.begin_array("a{sv}")!!;
		w.begin_dict_entry()!!;
		w.append_string("Name")!!;
		w.begin_variant("s")!!;
		w.append_string("bleu")!!;
		w.end_variant()!!;
		w.end_dict_entry()!!;
		w.begin_dict_entry()!!;
		w.append_string("Count")!!;
		w.begin_variant("u")!!;
		w.append_u32(7)!!;
		w.end_variant()!!;
		w.end_dict_entry()!!;
		w.begin_dict_entry()!!;
		w.append_string("Nested")!!;
		w.begin_variant("a{sv}")!!;
		w.begin_array("a{sv}")!!;
		w.begin_dict_entry()!!;
		w.append_string("k")!!;
		w.begin_variant("v")!!;
		w.begin_variant("d")!!;
		w.append_f64(1.5)!!;
		w.end_variant()!!;
		w.end_variant()!!;
		w.end_dict_entry()!!;
		w.end_array()!!;
		w.end_variant()!!;
		w.end_dict_entry()!!;
		w.end_array()!!;
		w.finish()!!;
		testing::expect_bytes(
			w.bytes(),
			"60 00 00 00 00 00 00 00 04 00 00 00 4e 61 6d 65 00 01 73 00 04 00 00 00 62 6c 65 75 00 00 00 00 05 00 00 00 43 6f 75 6e 74 00 01 75 00 00 00 00 07 00 00 00 00 00 00 00 06 00 00 00 4e 65 73 74 65 64 00 05 61 7b 73 76 7d 00 00 00 18 00 00 00 01 00 00 00 6b 00 01 76 00 01 64 00 00 00 00 00 00 00 00 00 00 00 f8 3f"
		);
	};
}

fn void writes_an_array_of_structs_with_variants() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "a(yv)")!!;
		w.begin_array("a(yv)")!!;
		w.begin_struct()!!;
		w.append_byte(1)!!;
		w.begin_variant("s")!!;
		w.append_string("x")!!;
		w.end_variant()!!;
		w.end_struct()!!;
		w.begin_struct()!!;
		w.append_byte(2)!!;
		w.begin_variant("u")!!;
		w.append_u32(9)!!;
		w.end_variant()!!;
		w.end_struct()!!;
		w.end_array()!!;
		w.finish()!!;
		testing::expect_bytes(
			w.bytes(),
			"18 00 00 00 00 00 00 00 01 01 73 00 01 00 00 00 78 00 00 00 00 00 00 00 02 01 75 00 09 00 00 00"
		);
	};
}
// Big-endian scalars and their alignment: the spec's byte order rule, checked
// on values whose bytes are easy to read by eye.
fn void writes_big_endian_scalars() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "yqud", true)!!;
		w.append_byte(0xAB)!!;
		w.append_u16(0x1234)!!;
		w.append_u32(0x01020304)!!;
		w.append_f64(1.0)!!;
		w.finish()!!;
		testing::expect_bytes(w.bytes(), "ab 00 12 34 01 02 03 04 3f f0 00 00 00 00 00 00");
	};
	@pool()
	{
		Reader r;
		r.init(testing::from_hex("ab 00 12 34 01 02 03 04 3f f0 00 00 00 00 00 00"), "yqud", true)!!;
		assert(r.read_byte()!! == 0xAB);
		assert(r.read_u16()!! == 0x1234);
		assert(r.read_u32()!! == 0x01020304);
		assert(r.read_f64()!! == 1.0);
		r.finish()!!;
	};
}