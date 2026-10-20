<*
 The sysfs side of the Linux backend: backlight class devices and keyboard LEDs.

 `/sys/class/backlight/<name>` has `brightness` (the setpoint),
 `actual_brightness` (the hardware's own report) and `max_brightness`; LEDs under
 `/sys/class/leds` have `brightness` and `max_brightness`. Every path is under
 the backend's root, so tests run against a fake tree.

 Source: Documentation/ABI/stable/sysfs-class-backlight and
 Documentation/ABI/testing/sysfs-class-led (https://docs.kernel.org/admin-guide/abi-testing-files.html).
*>
module bleu::brightness::sysfs @feat(LINUX);
import std::collections::maybe, std::io::path, bleu::availability, bleu::brightness, bleu::error, bleu::rt::fs, bleu::unit;

const String BACKLIGHT_CLASS = "/sys/class/backlight";
const String LED_CLASS = "/sys/class/leds";
const String DRM_CLASS = "/sys/class/drm";

<* Largest attribute read: a sysfs value is one short line. *>
const sz ATTRIBUTE_CAPACITY = 128;

<* `access(2)` mode asking whether the file may be written. *>
const int W_OK = 2;

extern fn int access(char* path, int mode);

<* The integer in attribute `file` of `dir`, or `NOT_FOUND` when it is absent or not a number. *>
fn long? read_number(String dir, String file)
{
	@pool()
	{
		return fs::read_integer(string::tformat("%s/%s", dir, file));
	};
}

<*
 One attribute of a class device as text, copied into `allocator`. The path is
 formatted in the caller's temporary scope, so call it inside a `@pool()`.

 @return? NOT_FOUND : "The attribute is absent or empty"
*>
fn String? read_text(Allocator allocator, String dir, String file)
{
	char[ATTRIBUTE_CAPACITY] buffer;
	String value = fs::read_trimmed(string::tformat("%s/%s", dir, file), buffer[..])!;
	if (value.len == 0) return NOT_FOUND~;
	return value.copy(allocator);
}

<* Whether `file` exists and this process may write to it. *>
fn bool writable_file(String file)
{
	@pool()
	{
		return path::exists((Path)file) && access(file.zstr_tcopy(), W_OK) == 0;
	};
}

<*
 The names of the entries of `root` + `directory`, copied into `allocator`. Uses
 the caller's temporary scope, so call it inside a `@pool()`.

 @return? NOT_FOUND, error::PERMISSION_DENIED, error::BACKEND_FAILURE : "The directory could not be read"
*>
fn String[]? entries(Allocator allocator, String root, String directory)
{
	PathList names = fs::list_dir(tmem, string::tformat("%s%s", root, directory))!;
	String[] result = alloc::new_array(allocator, String, (sz)names.len);
	foreach (i, name : names) result[i] = ((String)name).copy(allocator);
	return result;
}

<*
 The panel backlight: the best-ranked backlight class device under `root`, by
 `type` (see `sysfs_convert.type_rank`), copied into `allocator`.

 @return? NOT_FOUND : "There is no backlight class device"
*>
fn String? select_backlight(Allocator allocator, String root)
{
	@pool()
	{
		String[] names = entries(tmem, root, BACKLIGHT_CLASS)!;
		int[] ranks = alloc::new_array(tmem, int, names.len);
		foreach (i, name : names)
		{
			String type = read_text(tmem, string::tformat("%s%s/%s", root, BACKLIGHT_CLASS, name), "type") ?? "";
			ranks[i] = type_rank(type);
		}
		sz best = select_best(ranks, names);
		if (best < 0) return NOT_FOUND~;
		return names[best].copy(allocator);
	};
}

<*
 The control of a brightness knob `name` in `directory` (a class directory under
 `root`): `brightness` read against `max_brightness`. `actual_brightness`, when
 present, is the value read back, the hardware's own report; otherwise
 `brightness` is. The knob is writable when the logind route is up or the file
 itself is writable.
*>
fn Control knob_control(Mechanism mechanism, String root, String directory, String name, bool logind_up)
{
	@pool()
	{
		String dir = string::tformat("%s%s/%s", root, directory, name);
		long max = read_number(dir, "max_brightness") ?? 0;
		long raw = 0;
		bool readable = false;
		if (try actual = read_number(dir, "actual_brightness"))
		{
			raw = actual;
			readable = true;
		}
		else if (try setpoint = read_number(dir, "brightness"))
		{
			raw = setpoint;
			readable = true;
		}
		if (max <= 0 || !readable)
		{
			return {
				.mechanism = mechanism,
				.availability = availability::no(HARDWARE_ABSENT, "the knob has no readable brightness or maximum"),
			};
		}
		bool writable = logind_up || writable_file(string::tformat("%s/brightness", dir));
		Availability state = writable
			? availability::YES
			: availability::no(PERMISSION_NEEDED, "logind is not reachable and the brightness file is not writable");
		return {
			.mechanism = mechanism,
			.readable = true,
			.writable = writable,
			.availability = state,
			.level = maybe::value(unit::from_raw(raw, 0, max)),
			.raw = maybe::value(raw),
			.raw_min = 0,
			.raw_max = max,
		};
	};
}

<*
 Write `raw` to `brightness` of the class device `name` in `directory` under
 `root`, directly. This is the fallback when logind does not carry the write.

 @return? error::PERMISSION_DENIED, error::BACKEND_FAILURE : "The file could not be written"
*>
fn void? write_knob(String root, String directory, String name, long raw)
{
	@pool()
	{
		fs::write_text(string::tformat("%s%s/%s/brightness", root, directory, name), string::tformat("%d", raw))!;
	};
}

<* Whether `root` has the sysfs class directory `directory`. *>
fn bool has_class(String root, String directory)
{
	@pool()
	{
		return path::is_dir((Path)string::tformat("%s%s", root, directory));
	};
}
