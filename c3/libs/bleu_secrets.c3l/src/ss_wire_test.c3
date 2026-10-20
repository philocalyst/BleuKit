module bleu::secrets::ss_wire_test;
import bleu::error, bleu::secrets::ss, bleu::dbus::marshal, bleu::dbus::value;

// A Secret written with the Writer and read back through the Reader and the Value tree.
fn void secret_round_trips_through_marshalling() @test
{
	char[16] iv  = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
	char[] value = { 0x00, 0xFF, 0x7E, 0x42 };
	ss::WireSecret secret = {
		.session = "/org/freedesktop/secrets/session/s1",
		.parameters = iv[..],
		.value = value,
		.content_type = ss::CONTENT_TYPE
	};
	Writer w;
	w.init(tmem, "(oayays)")!!;
	ss::write_secret(&w, secret)!!;
	w.finish()!!;
	Reader r;
	r.init(w.bytes(), "(oayays)")!!;
	Value decoded = r.read_value(tmem)!!;
	r.finish()!!;
	ss::WireSecret back = ss::read_secret(decoded, tmem)!!;
	assert(back.session == secret.session);
	assert(back.parameters == iv[..]);
	assert(back.value == value);
	assert(back.content_type == ss::CONTENT_TYPE);
}

fn void a_struct_with_the_wrong_arity_is_refused() @test
{
	Value bad = value::structure(tmem, { value::u32(1) })!!;
	assert(@catch(ss::read_secret(bad, tmem)) == error::PROTOCOL);
}