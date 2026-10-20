// Unit tests for bleu::dbus::signature. Cases come from the D-Bus specification
// ("Type System", "Valid Signatures") and the limits it states.
module bleu::dbus::signature_test;
import bleu::dbus::signature;

fn void accepts_valid_signatures() @test
{
	assert(signature::valid(""));
	assert(signature::valid("i"));
	assert(signature::valid("ii"));
	assert(signature::valid("aiai"));
	assert(signature::valid("(ii)(ii)"));
	assert(signature::valid("(i(ii))"));
	assert(signature::valid("a(ii)"));
	assert(signature::valid("aai"));
	assert(signature::valid("a{sv}"));
	assert(signature::valid("a{oa{sa{sv}}}"));
	assert(signature::valid("v"));
	assert(signature::valid("sa{ss}ao"));
}

fn void rejects_invalid_signatures() @test
{
	assert(!signature::valid("aa"));        // array without element type
	assert(!signature::valid("(ii"));       // unclosed struct
	assert(!signature::valid("ii)"));       // unopened struct
	assert(!signature::valid("()"));        // empty struct
	assert(!signature::valid("{sv}"));      // dict entry outside an array
	assert(!signature::valid("a{vs}"));     // container as key
	assert(!signature::valid("a{sss}"));    // three fields in a dict entry
	assert(!signature::valid("a{s}"));      // one field in a dict entry
	assert(!signature::valid("r"));         // STRUCT code is reserved
	assert(!signature::valid("e"));         // DICT_ENTRY code is reserved
	assert(!signature::valid("*"));         // reserved for bindings
	assert(!signature::valid("m"));         // reserved for GVariant maybe
	assert(!signature::valid("(i}"));
}

fn void enforces_depth_limits() @test
{
	// 32 nested arrays are the limit; 33 are not.
	assert(signature::valid("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaai"));
	assert(!signature::valid("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaai"));
	// 32 nested structs are the limit; 33 are not.
	assert(signature::valid("((((((((((((((((((((((((((((((((i))))))))))))))))))))))))))))))))"));
	assert(!signature::valid("(((((((((((((((((((((((((((((((((i)))))))))))))))))))))))))))))))))"));
}

fn void enforces_length_limit() @test
{
	char[255] yyy;
	for (usz i = 0; i < 255; i++) yyy[i] = 'y';
	assert(signature::valid((String)yyy[:255]));
	char[256] too_long;
	for (usz i = 0; i < 256; i++) too_long[i] = 'y';
	assert(!signature::valid((String)too_long[:256]));
}

fn void reports_alignments() @test
{
	assert(signature::alignment_of("y") == 1);
	assert(signature::alignment_of("g") == 1);
	assert(signature::alignment_of("v") == 1);
	assert(signature::alignment_of("n") == 2);
	assert(signature::alignment_of("q") == 2);
	assert(signature::alignment_of("b") == 4);
	assert(signature::alignment_of("i") == 4);
	assert(signature::alignment_of("u") == 4);
	assert(signature::alignment_of("h") == 4);
	assert(signature::alignment_of("s") == 4);
	assert(signature::alignment_of("o") == 4);
	assert(signature::alignment_of("a") == 4);
	assert(signature::alignment_of("x") == 8);
	assert(signature::alignment_of("t") == 8);
	assert(signature::alignment_of("d") == 8);
	assert(signature::alignment_of("(y)") == 8);
	assert(signature::alignment_of("{sv}") == 8);
}

fn void splits_complete_types() @test
{
	TypeIterator it = signature::iterate("a{sv}(ii)s");
	String first = it.next()!!;
	assert(first == "a{sv}");
	String second = it.next()!!;
	assert(second == "(ii)");
	String third = it.next()!!;
	assert(third == "s");
	assert(!it.has_next());
}

fn void recognises_single_types() @test
{
	assert(signature::is_single("i"));
	assert(signature::is_single("(ii)"));
	assert(signature::is_single("a{sv}"));
	assert(!signature::is_single("ii"));
	assert(!signature::is_single(""));
}
