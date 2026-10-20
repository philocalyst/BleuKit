module bleu::rt::fs_test;
import bleu::rt::fs, bleu::error, std::core::test, std::core::string, std::io, std::io::path, std::time::clock;

// A scratch file in the system temp directory, unique per run.
fn String scratch_path(String stem) @local
{
	return string::tformat("/tmp/bleu-rt-%s-%d", stem, clock::now());
}

fn void sysfs_style_knob_round_trips() @test
{
	String path = scratch_path("knob");
	fs::write_text(path, "42\n")!!;
	test::eq(42, fs::read_integer(path)!!);
	char[16] buffer;
	test::@check((String)fs::read_trimmed(path, buffer[..])!! == "42", "trailing newline is trimmed");
	fs::write_text(path, "7")!!;
	test::eq(7, fs::read_integer(path)!!);
	io::file::delete(path)!!;
	test::@error(fs::read_integer(path), NOT_FOUND);
}

fn void a_non_integer_is_a_protocol_error() @test
{
	String path = scratch_path("text");
	fs::write_text(path, "not a number")!!;
	test::@error(fs::read_integer(path), error::PROTOCOL);
	io::file::delete(path)!!;
}

fn void a_file_longer_than_the_buffer_is_refused() @test
{
	String path = scratch_path("long");
	fs::write_text(path, "0123456789")!!;
	char[4] buffer;
	test::@error(fs::read_trimmed(path, buffer[..]), error::PROTOCOL);
	io::file::delete(path)!!;
}

fn void directory_listing_names_its_entries() @test
{
	// A directory of our own: listing a shared directory such as /tmp is slow and
	// its contents are not ours to assume.
	String dir = scratch_path("listing");
	io::path::mkdir(dir)!!;
	String file = string::tformat("%s/entry", dir);
	fs::write_text(file, "x")!!;
	PathList names = fs::list_dir(tmem, dir)!!;
	bool found     = false;
	foreach (entry : names)
	{
		if ((String)entry == "entry") found = true;
	}
	test::@check(found, "the file appears in its directory's listing");
	io::file::delete(file)!!;
	io::path::rmdir((Path)dir)!!; // a String argument trips std::io::path::rmdir (see the research notes)
}