<*
 File-system helpers for the Linux backends: sysfs and procfs knobs, and the
 directory listings that go with them. Errors from `std::io` are translated into
 the Bleu excuse vocabulary, so a backend never sees a standard-library fault.

 Sysfs and procfs attributes do not report their size reliably: stat(2) gives 0
 or 4096 whatever they hold. So files are read to end-of-file, never sized from
 stat, and a file longer than the buffer is an error rather than a truncation.
*>
module bleu::rt::fs;
import std::io, std::io::path, bleu::error;

<* Largest file `read_file` accepts. Sysfs and procfs attributes are far smaller. *>
const usz MAX_SMALL_FILE = 64 * 1024;

<* Largest integer text `read_integer` considers; a decimal `long` needs 20 characters. *>
const usz MAX_INTEGER_TEXT = 32;

<*
 Read a whole small file into memory, allocated from `allocator`. The caller
 frees it with `alloc::free(allocator, data.ptr)`.

 @return? error::PROTOCOL : "The file is longer than `MAX_SMALL_FILE`"
 @return? NOT_FOUND, error::PERMISSION_DENIED, error::BACKEND_FAILURE : "The file could not be read"
*>
fn String? read_file(Allocator allocator, String path)
{
	char[] buffer = alloc::new_array(allocator, char, MAX_SMALL_FILE);
	defer catch alloc::free(allocator, buffer.ptr);
	return read_into(path, buffer);
}

<*
 Read a whole small file into `buffer` and return the text with trailing
 whitespace (including the newline sysfs appends) removed.

 @param buffer : "Receives the file; a file longer than it is an error"
 @return? error::PROTOCOL : "The file does not fit in `buffer`"
 @return? NOT_FOUND, error::PERMISSION_DENIED, error::BACKEND_FAILURE : "The file could not be read"
*>
fn String? read_trimmed(String path, char[] buffer)
{
	String text = read_into(path, buffer)!;
	return text.trim();
}

<*
 Read a file holding one decimal integer, such as a sysfs brightness value.

 @return? error::PROTOCOL : "The file does not hold a decimal integer"
 @return? NOT_FOUND, error::PERMISSION_DENIED, error::BACKEND_FAILURE : "The file could not be read"
*>
fn long? read_integer(String path)
{
	char[MAX_INTEGER_TEXT] buffer;
	String text = read_trimmed(path, buffer[..])!;
	long? value = text.to_long();
	if (catch err = value)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "%s does not hold an integer", path)~;
	}
	return value;
}

<*
 Replace the contents of a sysfs or procfs knob with `text`: one open, one
 write, one close. Such files cannot be renamed into place, so there is no
 atomic-replace step; a short write is reported, not retried.

 @return? error::INVALID_ARGUMENT : "The kernel rejected the value"
 @return? NOT_FOUND, error::PERMISSION_DENIED, error::BACKEND_FAILURE : "The file could not be written"
*>
fn void? write_text(String path, String text)
{
	if (catch err = io::file::save(path, text)) return io_error("write", path, err)~;
}

<*
 Names of the entries in a directory, relative to it (no "." or "..").
 The list and its entries are allocated from `allocator`; a short-lived listing
 belongs in `tmem`.

 @return? NOT_FOUND, error::PERMISSION_DENIED, error::BACKEND_FAILURE : "The directory could not be read"
*>
fn PathList? list_dir(Allocator allocator, String dir)
{
	PathList? listed = path::ls(allocator, (Path)dir);
	if (catch err = listed) return io_error("list", dir, err)~;
	return listed;
}

// The text of a file, read into `buffer`, with a check that it all fit.
fn String? read_into(String path, char[] buffer) @private
{
	io::File? opened = io::file::open(path, "rb");
	if (catch err = opened) return io_error("open", path, err)~;
	io::File file = opened;
	defer (void)file.close();
	char[]? read = io::read_buffer_to_end(file, buffer);
	if (catch err = read) return io_error("read", path, err)~;
	String data = (String)read;
	if (data.len < buffer.len) return data;
	// Full: the file is exactly this long, or longer. One more byte tells which, and
	// only an end-of-file reply means the file ended here; any other fault is a read failure.
	if (catch err = file.read_byte())
	{
		if (err == io::EOF) return data;
		return io_error("read", path, err)~;
	}
	return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "%s is longer than %d bytes", path, buffer.len)~;
}

// Translate a standard-library fault into the Bleu excuse vocabulary. The native
// code is not kept: std::io's faults do not carry it, and errno is not read back
// after the standard library's own calls, so `Domain.NONE` says so honestly.
fn fault io_fault(fault f) @private
{
	switch (f)
	{
		case io::FILE_NOT_FOUND:
		case io::PATH_COULD_NOT_BE_FOUND: return NOT_FOUND;
		case io::NO_PERMISSION:
		case io::READ_ONLY: return error::PERMISSION_DENIED;
		case io::BUSY: return error::BUSY;
		case io::ILLEGAL_ARGUMENT:
		case io::FILE_IS_DIR:
		case io::FILE_NOT_DIR:
		case io::NAME_TOO_LONG: return error::INVALID_ARGUMENT;
		case io::OUT_OF_SPACE:
		case io::OVERFLOW: return error::OUT_OF_RANGE;
		default: return error::BACKEND_FAILURE;
	}
}

// Record an I/O failure against `what` and return the matching fault.
fn fault io_error(String operation, String target, fault f) @private
{
	return error::raise(io_fault(f), error::Domain.NONE, 0, "%s of %s failed", operation, target);
}