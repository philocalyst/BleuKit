<*
 One sample of the whole machine from /proc and /sys. Everything read is in
 tmem; only the published state and the counters kept for the next sample are
 copied out, so no sample leaks memory into the next one.
*>
module bleu::sysinfo::procfs @feat(LINUX);
import std::time, std::collections::maybe, bleu::error, bleu::observe, bleu::rt::fs, bleu::rt::unix, bleu::sysinfo, bleu::sysinfo::delta, libc;

<*
 Read one sample into `snapshot`. The first sample has no earlier counters, so
 every rate and share in it is empty.

 @return? NOT_FOUND, error::PROTOCOL, error::BACKEND_FAILURE : "A file the sample needs is missing or malformed"
*>
fn void? sample(void* reader, Snapshot{State}* snapshot, Duration elapsed)
{
	ProcfsBackend* backend = (ProcfsBackend*)reader;
	Allocator allocator = snapshot.allocator();
	State* state = &snapshot.value;
	@pool()
	{
		String root = backend.root;
		delta::CpuLine[] lines = procfs::parse_stat(read_text(root, "/proc/stat")!, tmem)!;
		uint processors = sysinfo::count_processors(lines);
		sample_cpu(backend, allocator, &state.cpu, lines)!;
		sample_memory(root, &state.memory)!;
		state.mounts = read_mounts(root, allocator)!;
		delta::NetCounters[] counters = read_net_counters(root)!;
		state.interfaces = sysinfo::interface_rates(&backend.previous_net, allocator, counters, elapsed);
		state.temperatures = read_temperatures(root, allocator);
		CLong clock_ticks = sys_sysconf(SC_CLK_TCK);
		ulong ticks_per_second = clock_ticks > 0 ? (ulong)clock_ticks : 0;
		ProcessSample[] all = read_processes(backend, elapsed, processors, ticks_per_second)!;
		state.processes = sysinfo::top_processes(backend.process_count, allocator, all);
		state.identity = read_identity(root, allocator)!;
		// Commit the counters only after every file was read, so a failed sample leaves no half-updated history.
		backend.previous_cpu.clear();
		backend.previous_cpu.push_all(lines);
		sysinfo::replace_counters(&backend.previous_net, backend.allocator, counters);
		backend.previous_processes.clear();
		foreach (&sampled : all)
		{
			backend.previous_processes.push(sampled.ticks);
		}
	};
	return;
}

fn void? sample_cpu(ProcfsBackend* backend, Allocator allocator, Cpu* cpu, delta::CpuLine[] lines)
{
	String root = backend.root;
	cpu.model = procfs::cpuinfo_model(read_text(root, "/proc/cpuinfo") ?? "", allocator);
	cpu.load_average = procfs::parse_loadavg(read_text(root, "/proc/loadavg")!)!;
	sysinfo::fill_cpu(cpu, allocator, lines, backend.previous_cpu.array_view());
	foreach (i, &core : cpu.cores)
	{
		core.frequency = core_frequency(root, (int)i);
	}
}

// The share of the processor `index` (-1 for all of them) that was busy since `earlier`.
fn Maybe{Mhz} core_frequency(String root, int index)
{
	String path = string::tformat("%s/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq", root, index);
	if (try khz = fs::read_integer(path)) return maybe::value((Mhz)(khz / 1000));
	return {};
}

fn void? sample_memory(String root, Memory* memory)
{
	MemInfo info = procfs::parse_meminfo(read_text(root, "/proc/meminfo")!)!;
	memory.total = info.total;
	memory.available = info.available < info.total ? info.available : info.total;
	memory.used = info.total - memory.available;
	memory.cache = maybe::value(sysinfo::sub_or_zero(info.buffers + info.cached + info.sreclaimable, info.shmem));
	memory.swap_total = info.swap_total;
	memory.swap_used = sysinfo::sub_or_zero(info.swap_total, info.swap_free);
}

fn Identity? read_identity(String root, Allocator allocator)
{
	Identity identity;
	identity.hostname = (read_attribute(string::tformat("%s/proc/sys/kernel/hostname", root)) ?? "").copy(allocator);
	identity.os = procfs::os_release_value(read_text(root, "/etc/os-release") ?? "", "PRETTY_NAME", allocator);
	if (identity.os.len == 0) identity.os = "Linux";
	Utsname names;
	if (sys_uname(&names) != 0) return unix::errno_fault("uname", libc::errno())~;
	identity.kernel = ((ZString)&names.release).str_view().copy(allocator);
	identity.arch = ((ZString)&names.machine).str_view().copy(allocator);
	identity.uptime = procfs::parse_uptime(read_text(root, "/proc/uptime")!)!;
	return identity;
}
