<*
 Reading the kernel's text files under `Options.root`. Results live in `tmem`:
 the sampler opens one pool per sample and copies what must outlive it.
*>
module bleu::sysinfo::procfs @feat(LINUX);
import std::io::path, bleu::rt::fs;

<* Largest single-line attribute (sysfs or /proc/<pid>/...) read into a stack buffer. *>
const usz ATTRIBUTE_CAPACITY = 256;

<* The whole text of the file at `root` + `relative` (for example "/proc/stat"). *>
fn String? read_text(String root, String relative)
{
	return fs::read_file(tmem, string::tformat("%s%s", root, relative));
}

<* One trimmed line of a sysfs attribute, copied into tmem. *>
fn String? read_attribute(String path)
{
	char[ATTRIBUTE_CAPACITY] buffer;
	String text = fs::read_trimmed(path, buffer[..])!;
	return text.copy(tmem);
}

<* Whether `path` exists as a directory or file under the fake or real root. *>
fn bool exists(String path) @inline => path::is_dir((Path)path) || path::is_file((Path)path);
