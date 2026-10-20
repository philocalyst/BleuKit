module bleu::objc::encoding;

// The primitive codes from the `@encode` table, with the BOOL rule of this target.
fn void primitive_codes() @test
{
	assert(type_code(void).str_view() == "v");
	assert(type_code(ichar).str_view() == "c");
	assert(type_code(short).str_view() == "s");
	assert(type_code(int).str_view() == "i");
	assert(type_code(long).str_view() == "q");
	assert(type_code(char).str_view() == "C");
	assert(type_code(ushort).str_view() == "S");
	assert(type_code(uint).str_view() == "I");
	assert(type_code(ulong).str_view() == "Q");
	assert(type_code(float).str_view() == "f");
	assert(type_code(double).str_view() == "d");
	assert(type_code(void*).str_view() == "@");
	$if $feat(AARCH64):
		assert(type_code(bool).str_view() == "B");
	$else
		assert(type_code(bool).str_view() == "c");
	$endif
}

// Whole method encodings: return type, the implied receiver and selector, then the arguments.
fn void method_signatures() @test
{
	assert(signature(void, (void*)null).str_view() == "v@:@");
	assert(signature(double).str_view() == "d@:");
	assert(signature(int, (ulong)0).str_view() == "i@:Q");
	assert(signature(void, (void*)null, (double)0.0).str_view() == "v@:@d");
}
