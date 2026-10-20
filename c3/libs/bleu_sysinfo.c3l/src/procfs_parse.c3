<*
 Parsers for the text that Linux exposes under /proc, /sys and /etc.

 Pure: they take the text of a file and return values, so the golden tests in
 `procfs_parse_test.c3` run on any host with the same kernel formats the
 sandbox produced. Formats are documented in proc(5), Documentation/filesystems/proc.rst
 (https://docs.kernel.org/filesystems/proc.html) and Documentation/ABI for sysfs.

 Scratch memory comes from `tmem`: callers wrap these in `@pool()`, and results
 that must outlive the pool are copied into the allocator they pass.
*>
module bleu::sysinfo::procfs;
import std::collections::list, std::time, bleu::error, bleu::unit, bleu::sysinfo, bleu::sysinfo::delta;

const usz MICROSECOND_DIGITS = 6;

<* Whitespace that separates the fields of the kernel's text files. *>
fn bool is_space(char c) @inline => c == ' ' || c == '\t' || c == '\n' || c == '\r';

<*
 The next whitespace-separated field of `text` at or after `*cursor`, and moves
 the cursor past it. The field is a slice of `text`; nothing is allocated.

 @return? NO_MORE_ELEMENT : "No field is left"
*>
fn String? next_field(String text, sz* cursor)
{
	sz i = *cursor;
	while (i < text.len && is_space(text[i])) i++;
	if (i >= text.len)
	{
		*cursor = i;
		return NO_MORE_ELEMENT~;
	}
	sz start = i;
	while (i < text.len && !is_space(text[i])) i++;
	*cursor = i;
	return text[start : i - start];
}

<* Parse a decimal count, rejecting anything that is not digits. *>
fn ulong? parse_count(String text)
{
	if (text.len == 0) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "empty number")~;
	ulong value = 0;
	foreach (c : text)
	{
		if (c < '0' || c > '9') return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "'%s' is not a count", text)~;
		value = value * 10 + (ulong)(c - '0');
	}
	return value;
}

<* The text after the first `:` on `line`, and the text before it, or both empty when there is no `:`. *>
fn bool split_key(String line, String* key, String* value) @inline
{
	if (try colon = line.index_of_char(':'))
	{
		*key = line[0 : colon].trim();
		*value = line[colon + 1 : line.len - colon - 1].trim();
		return true;
	}
	return false;
}

<* One `cpu` line of /proc/stat. `index` is -1 for the aggregate line `cpu`. *>
struct CpuLine
{
	int index;
	Ticks ticks;
}

<*
 Read every `cpu` line of /proc/stat. The first seven fields after the name are
 user, nice, system, idle, iowait, irq, softirq (proc(5), "/proc/stat"). Guest
 time is already inside user and guest_nice inside nice, so it is not added
 again. Steal is left out of the total, as sysinfo does.

 @return? error::PROTOCOL : "A cpu line is malformed or there is no aggregate line"
*>
fn CpuLine[]? parse_stat(String text, Allocator allocator)
{
	List{CpuLine} lines;
	lines.init(tmem);
	bool has_aggregate = false;
	foreach (line : text.tokenize("\n"))
	{
		if (!line.starts_with("cpu")) continue;
		sz cursor = 0;
		String name = next_field(line, &cursor)!;
		ulong[7] values;
		foreach (&value : values)
		{
			*value = parse_count(next_field(line, &cursor)!)!;
		}
		int index = -1;
		if (name != "cpu")
		{
			index = (int)parse_count(name[3 : name.len - 3])!;
		}
		else
		{
			has_aggregate = true;
		}
		ulong busy = values[0] + values[1] + values[2] + values[5] + values[6];
		lines.push({ .index = index, .ticks = { .busy = busy, .total = busy + values[3] + values[4] } });
	}
	if (!has_aggregate) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "no aggregate cpu line")~;
	return alloc::clone_slice(allocator, lines.array_view());
}

<* Memory figures from /proc/meminfo, in bytes. *>
struct MemInfo
{
	ulong total;
	ulong available;
	ulong buffers;
	ulong cached;
	ulong sreclaimable;
	ulong shmem;
	ulong swap_total;
	ulong swap_free;
}

<*
 Read /proc/meminfo (values in kB; proc(5)). `available` is MemAvailable; kernels
 older than 3.14 lack it, and then it is estimated as sysinfo does: free plus
 buffers, cache and reclaimable slab, less shmem.

 @return? error::PROTOCOL : "MemTotal is missing or a line is malformed"
*>
fn MemInfo? parse_meminfo(String text)
{
	MemInfo info;
	ulong free = 0;
	bool has_available = false;
	foreach (line : text.tokenize("\n"))
	{
		String key;
		String value;
		if (!split_key(line, &key, &value)) continue;
		if (key == "MemTotal") info.total = kib_value(value)!;
		else if (key == "MemFree") free = kib_value(value)!;
		else if (key == "MemAvailable")
		{
			info.available = kib_value(value)!;
			has_available = true;
		}
		else if (key == "Buffers") info.buffers = kib_value(value)!;
		else if (key == "Cached") info.cached = kib_value(value)!;
		else if (key == "SReclaimable") info.sreclaimable = kib_value(value)!;
		else if (key == "Shmem") info.shmem = kib_value(value)!;
		else if (key == "SwapTotal") info.swap_total = kib_value(value)!;
		else if (key == "SwapFree") info.swap_free = kib_value(value)!;
	}
	if (info.total == 0) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "MemTotal is missing")~;
	if (!has_available)
	{
		ulong estimate = free + info.buffers + info.cached + info.sreclaimable;
		info.available = estimate > info.shmem ? estimate - info.shmem : 0;
	}
	return info;
}

<* A "<number> kB" value from /proc/meminfo, in bytes. *>
fn ulong? kib_value(String value)
{
	sz cursor = 0;
	ulong kib = parse_count(next_field(value, &cursor)!)!;
	return kib * 1024;
}

<*
 Read /proc/loadavg: the 1, 5 and 15 minute averages (proc(5), "/proc/loadavg").

 @return? error::PROTOCOL : "The first three fields are not decimal numbers"
*>
fn LoadAverage[3]? parse_loadavg(String text)
{
	sz cursor = 0;
	LoadAverage[3] averages;
	foreach (&average : averages)
	{
		String field = next_field(text, &cursor)!;
		*average = field.to_float()!;
	}
	return averages;
}

<*
 Read the uptime (first field of /proc/uptime, seconds with up to two decimals)
 as a Duration in microseconds.

 @return? error::PROTOCOL : "The field is not a decimal number"
*>
fn Duration? parse_uptime(String text)
{
	sz cursor = 0;
	String field = next_field(text, &cursor)!;
	String whole = field;
	String fraction = "";
	if (try dot = field.index_of_char('.'))
	{
		whole = field[0 : dot];
		fraction = field[dot + 1 : field.len - dot - 1];
	}
	long seconds = whole.to_long()!;
	long micro = 0;
	for (usz i = 0; i < MICROSECOND_DIGITS; i++)
	{
		long digit = 0;
		if (i < fraction.len)
		{
			ulong value = parse_count(fraction[i : 1])!;
			digit = (long)value;
		}
		micro = micro * 10 + digit;
	}
	return (Duration)(seconds * 1_000_000 + micro);
}

<* Cumulative byte counters of one network interface. *>
struct NetCounters
{
	String name;
	ulong received;
	ulong sent;
}

<*
 Read /proc/net/dev (proc(5), "/proc/net/dev"): two header lines, then one line
 per interface whose receive bytes are the first field after the colon and
 whose transmit bytes are the ninth. Loopback is left out. Names are copied
 into `allocator`.

 @return? error::PROTOCOL : "A line does not have the expected fields"
*>
fn NetCounters[]? parse_net_dev(String text, Allocator allocator)
{
	List{NetCounters} interfaces;
	interfaces.init(tmem);
	foreach (line : text.tokenize("\n"))
	{
		String name;
		String rest;
		if (!split_key(line, &name, &rest)) continue; // the two header lines have no colon-separated name
		if (name == "lo") continue;
		sz cursor = 0;
		ulong received = parse_count(next_field(rest, &cursor)!)!;
		for (usz skip = 0; skip < 7; skip++)
		{
			next_field(rest, &cursor)!;
		}
		ulong sent = parse_count(next_field(rest, &cursor)!)!;
		interfaces.push({ .name = name.copy(allocator), .received = received, .sent = sent });
	}
	return alloc::clone_slice(allocator, interfaces.array_view());
}

<* One line of /proc/mounts, with the kernel's octal escapes already undone. *>
struct RawMount
{
	String device;
	String mount_point;
	String fs_type;
}

<*
 Read /proc/mounts (fstab(5) format, "device mountpoint type options dump pass").
 Spaces, tabs, newlines and backslashes in the fields are written as octal
 escapes (\040 and so on) by the kernel (proc(5), "/proc/[pid]/mounts"); they
 are decoded here. Copies into `allocator`.

 @return? error::PROTOCOL : "A line has fewer than three fields"
*>
fn RawMount[]? parse_mounts(String text, Allocator allocator)
{
	List{RawMount} mounts;
	mounts.init(tmem);
	foreach (line : text.tokenize("\n"))
	{
		sz cursor = 0;
		String device = next_field(line, &cursor)!;
		String mount_point = next_field(line, &cursor)!;
		String fs_type = next_field(line, &cursor)!;
		mounts.push({
			.device = unescape_octal(device, allocator)!,
			.mount_point = unescape_octal(mount_point, allocator)!,
			.fs_type = fs_type.copy(allocator),
		});
	}
	return alloc::clone_slice(allocator, mounts.array_view());
}

<* Decode `\NNN` octal escapes; anything else is copied as it is. *>
fn String? unescape_octal(String text, Allocator allocator)
{
	char[] out = alloc::new_array(tmem, char, text.len);
	usz n = 0;
	usz i = 0;
	while (i < text.len)
	{
		if (text[i] == '\\' && text.len - i >= 4)
		{
			out[n] = (char)parse_octal(text[i + 1 : 3])!;
			i += 4;
		}
		else
		{
			out[n] = text[i];
			i++;
		}
		n++;
	}
	return ((String)out[:n]).copy(allocator);
}

<* Three octal digits as a byte value. *>
fn ulong? parse_octal(String digits)
{
	ulong value = 0;
	foreach (c : digits)
	{
		if (c < '0' || c > '7') return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "bad octal escape")~;
		value = value * 8 + (ulong)(c - '0');
	}
	return value;
}

<* Whether a mount source is a real disk worth listing: a block device other than a loop or RAM disk. *>
fn bool is_local_disk(String device) @inline
{
	return device.starts_with("/dev/") && !device.starts_with("/dev/loop") && !device.starts_with("/dev/ram");
}

<* Fields of /proc/<pid>/stat that the service uses. `name` is the command name from between the parentheses. *>
struct StatFields
{
	String name;
	ulong utime;
	ulong stime;
	ulong started;
}

<*
 Read /proc/<pid>/stat (proc(5), "/proc/[pid]/stat"). The command name can hold
 spaces and parentheses, so fields are counted from the last `)`.

 @return? error::PROTOCOL : "The line is not a stat record"
*>
fn StatFields? parse_pid_stat(String text)
{
	sz open = text.index_of_char('(')!;
	sz close = text.rindex_of_char(')')!;
	if (close <= open) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "no command name")~;
	StatFields fields = { .name = text[open + 1 : close - open - 1] };
	sz cursor = close + 1;
	// Field 3 (state) is the first after the name; utime is field 14, stime 15, starttime 22.
	for (usz field = 3; field <= 22; field++)
	{
		String token = next_field(text, &cursor)!;
		switch (field)
		{
			case 14: fields.utime = parse_count(token)!;
			case 15: fields.stime = parse_count(token)!;
			case 22: fields.started = parse_count(token)!;
			default: continue;
		}
	}
	return fields;
}

<* Fields of /proc/<pid>/status that the service uses. `has_rss` is false for kernel threads, which have no resident set. *>
struct StatusFields
{
	ulong uid;
	bool has_rss;
	ulong rss;
}

<*
 Read /proc/<pid>/status (proc(5), "/proc/[pid]/status"): the real user id and
 the resident set size in bytes.

 @return? error::PROTOCOL : "The Uid line is missing or malformed"
*>
fn StatusFields? parse_status(String text)
{
	StatusFields fields;
	bool has_uid = false;
	foreach (line : text.tokenize("\n"))
	{
		String key;
		String value;
		if (!split_key(line, &key, &value)) continue;
		if (key == "Uid")
		{
			sz cursor = 0;
			fields.uid = parse_count(next_field(value, &cursor)!)!;
			has_uid = true;
		}
		else if (key == "VmRSS")
		{
			fields.rss = kib_value(value)!;
			fields.has_rss = true;
		}
	}
	if (!has_uid) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "no Uid line")~;
	return fields;
}

<*
 Read /proc/<pid>/cmdline: arguments separated by NUL bytes. Returned as one
 line with spaces between arguments, copied into `allocator`. Empty for kernel
 threads, which have no command line.
*>
fn String command_line(String raw, Allocator allocator)
{
	char[] out = alloc::new_array(tmem, char, raw.len);
	for (usz i = 0; i < raw.len; i++)
	{
		out[i] = raw[i] == 0 ? ' ' : raw[i];
	}
	return ((String)out).trim().copy(allocator);
}

<* The value of the first "model name" line of /proc/cpuinfo, or "" (ARM kernels print none). *>
fn String cpuinfo_model(String text, Allocator allocator)
{
	foreach (line : text.tokenize("\n"))
	{
		String key;
		String value;
		if (!split_key(line, &key, &value)) continue;
		if (key == "model name") return value.copy(allocator);
	}
	return "";
}

<*
 The value of `key` in /etc/os-release (os-release(5)): `KEY=value`, with the
 value optionally in double quotes. Returns "" when the key is absent.
*>
fn String os_release_value(String text, String key, Allocator allocator)
{
	foreach (line : text.tokenize("\n"))
	{
		if (!line.starts_with(key) || line.len <= key.len || line[key.len] != '=') continue;
		String value = line[key.len + 1 : line.len - key.len - 1].trim();
		if (value.len >= 2 && value[0] == '"' && value[value.len - 1] == '"')
		{
			value = value[1 : value.len - 2];
		}
		return value.copy(allocator);
	}
	return "";
}

<* The field `index` (from 0) of a colon-separated line, as a slice of `line`. *>
fn String? colon_field(String line, usz index)
{
	usz field = 0;
	sz start = 0;
	for (sz i = 0; i <= line.len; i++)
	{
		if (i == line.len || line[i] == ':')
		{
			if (field == index) return line[start : i - start];
			field++;
			start = i + 1;
		}
	}
	return NO_MORE_ELEMENT~;
}

<*
 The account name for `uid` in /etc/passwd text (passwd(5): name, password,
 uid, gid, ...). Returns a slice of `text`; copy it to keep it.

 @return? NOT_FOUND : "No account has that uid"
*>
fn String? passwd_name(String text, ulong uid)
{
	foreach (line : text.tokenize("\n"))
	{
		if (try uid_text = colon_field(line, 2))
		{
			if (try id = parse_count(uid_text))
			{
				if (id == uid) return colon_field(line, 0)!;
			}
		}
	}
	return NOT_FOUND~;
}

<*
 The number in a sysfs attribute or directory name of the form `prefix<N>suffix`,
 such as `temp3_input` (prefix "temp", suffix "_input") or `thermal_zone0`.

 @return? NOT_FOUND : "The name does not have that shape"
*>
fn int? numbered_name(String name, String prefix, String suffix)
{
	if (name.len <= prefix.len + suffix.len || !name.starts_with(prefix) || !name.ends_with(suffix)) return NOT_FOUND~;
	ulong number = parse_count(name[prefix.len : name.len - prefix.len - suffix.len])!;
	return (int)number;
}

<*
 A sysfs temperature in millidegrees Celsius (hwmon `temp*_input`, thermal
 `temp`), as degrees. The kernel writes these as plain decimal integers.

 @return? error::PROTOCOL : "The file does not hold an integer"
*>
fn Celsius? celsius_from_millidegrees(String text)
{
	long millidegrees = text.to_long()!;
	return (Celsius)((float)millidegrees / 1000.0f);
}
