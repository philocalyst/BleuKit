<*
 The process list from /proc/<pid>: name, command line, owner, resident memory
 and CPU share. A process that exits while it is being read is skipped; a
 field that cannot be read (another user's command line, a kernel thread's) is
 left empty.
*>
module bleu::sysinfo::procfs @feat(LINUX);
import std::io::path, std::time, std::collections::list, std::collections::maybe, bleu::rt::fs, bleu::sysinfo, bleu::sysinfo::busiest, bleu::sysinfo::delta;

<*
 Largest /proc/<pid>/cmdline the sampler reads. Longer command lines are
 reported as unknown (empty), not truncated.
*>
const usz PROCESS_TEXT_CAPACITY = 8192;

<* Every process that could be read in this sample, in tmem. *>
fn ProcessSample[]? read_processes(ProcfsBackend* backend, Duration elapsed, uint processors, ulong ticks_per_second)
{
	PathList entries = fs::list_dir(tmem, string::tformat("%s/proc", backend.root))!;
	String passwd = read_text(backend.root, "/etc/passwd") ?? "";
	List{ProcessSample} samples;
	samples.init(tmem);
	foreach (entry : entries)
	{
		if (try pid = procfs::parse_count((String)entry))
		{
			if (try reading = read_process(backend, (uint)pid, passwd, elapsed, processors, ticks_per_second))
			{
				samples.push(reading);
			}
		}
	}
	return samples.array_view();
}

fn ProcessSample? read_process(ProcfsBackend* backend, uint pid, String passwd, Duration elapsed, uint processors, ulong ticks_per_second)
{
	String root = backend.root;
	char[PROCESS_TEXT_CAPACITY] stat_buffer;
	StatFields stat = procfs::parse_pid_stat(fs::read_trimmed(string::tformat("%s/proc/%d/stat", root, pid), stat_buffer[..])!)!;
	String name = stat.name.copy(tmem);
	char[PROCESS_TEXT_CAPACITY] status_buffer;
	StatusFields status = procfs::parse_status(fs::read_trimmed(string::tformat("%s/proc/%d/status", root, pid), status_buffer[..])!)!;
	char[PROCESS_TEXT_CAPACITY] command_buffer;
	String raw_command = fs::read_trimmed(string::tformat("%s/proc/%d/cmdline", root, pid), command_buffer[..]) ?? "";
	ulong ticks = stat.utime + stat.stime;
	Maybe{Percent} cpu = {};
	if (try earlier = delta::find_process(backend.previous_processes.array_view(), pid, stat.started))
	{
		cpu = delta::process_percent(earlier.ticks, ticks, ticks_per_second, elapsed, processors);
	}
	Maybe{Bytes} memory = {};
	if (status.has_rss) memory = maybe::value(status.rss);
	String user = user_of(passwd, status.uid);
	return {
		.process = {
			.pid = pid,
			.name = name,
			.command = procfs::command_line(raw_command, tmem),
			.user = user,
			.cpu = cpu,
			.memory = memory,
		},
		.ticks = { .pid = pid, .started = stat.started, .ticks = ticks },
	};
}

// The account name for `uid`, or the number itself when /etc/passwd does not name it.
fn String user_of(String passwd, ulong uid)
{
	if (try name = procfs::passwd_name(passwd, uid)) return name;
	return string::tformat("%d", uid);
}

