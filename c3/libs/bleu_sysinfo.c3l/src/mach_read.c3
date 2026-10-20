<*
 The macOS readers: each returns plain values, temporaries in tmem, strings
 copied into the allocator the caller passes. Failures of a call the sample
 needs are errors; an absent optional sysctl is an empty string.
*>
module bleu::sysinfo::mach @feat(DARWIN);
import std::collections::list, std::collections::maybe, std::time, bleu::error, bleu::rt::unix, bleu::sysinfo, bleu::sysinfo::delta, libc;

<* One call to `host_processor_info`: per-processor load, aggregate first (index -1, as in /proc/stat). *>
fn delta::CpuLine[]? processor_lines()
{
	uint count = 0;
	ProcessorLoad* loads;
	uint info_count = 0;
	CInt kr = host_processor_info(mach_host_self(), (CInt)PROCESSOR_CPU_LOAD_INFO, &count, &loads, &info_count);
	if (kr != 0) return error::raise(error::BACKEND_FAILURE, error::Domain.MACH, kr, "host_processor_info failed")~;
	// The array is ours to release; its size in bytes is info_count integers.
	defer (void)vm_deallocate(mach_task_self_, (ulong)loads, (ulong)info_count * 4);
	delta::CpuLine[] lines = alloc::new_array(tmem, delta::CpuLine, (sz)count + 1);
	delta::Ticks total = { .busy = 0, .total = 0 };
	for (uint i = 0; i < count; i++)
	{
		ulong user = loads[i].cpu_ticks[CPU_STATE_USER];
		ulong system = loads[i].cpu_ticks[CPU_STATE_SYSTEM];
		ulong nice = loads[i].cpu_ticks[CPU_STATE_NICE];
		ulong idle = loads[i].cpu_ticks[CPU_STATE_IDLE];
		delta::Ticks ticks = { .busy = user + system + nice, .total = user + system + nice + idle };
		lines[i + 1] = { .index = (int)i, .ticks = ticks };
		total.busy += ticks.busy;
		total.total += ticks.total;
	}
	lines[0] = { .index = -1, .ticks = total };
	return lines;
}

fn LoadAverage[3]? load_averages()
{
	double[3] averages;
	if (sys_getloadavg(&averages[0], 3) != 3) return unix::errno_fault("getloadavg", libc::errno())~;
	LoadAverage[3] result;
	foreach (i, &average : averages)
	{
		result[i] = (LoadAverage)*average;
	}
	return result;
}

<*
 Physical and swap memory. `available` follows sysinfo's macOS rule: free,
 inactive and purgeable pages, less the pages held by the compressor (sysinfo
 0.33.1, unix/apple/system.rs; not checked against a Mac).
*>
fn Memory? memory_figures()
{
	ulong total = 0;
	sysctl_read("hw.memsize", &total, ulong::size)!;
	VmStatistics64 vm = vm_statistics()!;
	ulong page = (ulong)sys_getpagesize();
	ulong pages = (ulong)vm.free_count + vm.inactive_count + vm.purgeable_count;
	ulong available = sysinfo::sub_or_zero(pages, vm.compressor_page_count) * page;
	if (available > total) available = total;
	XswUsage swap;
	sysctl_read("vm.swapusage", &swap, @sizeof(swap))!;
	return {
		.total = total,
		.used = total - available,
		.available = available,
		.cache = maybe::value((ulong)vm.external_page_count * page),
		.swap_total = swap.total,
		.swap_used = swap.used,
	};
}

fn VmStatistics64? vm_statistics()
{
	VmStatistics64 stats;
	uint count = (uint)(@sizeof(stats) / 4);
	CInt kr = host_statistics64(mach_host_self(), HOST_VM_INFO64, &stats, &count);
	if (kr != 0) return error::raise(error::BACKEND_FAILURE, error::Domain.MACH, kr, "host_statistics64 failed")~;
	return stats;
}

// getmntinfo has a 64-bit-inode symbol on x86-64 (bsd/sys/cdefs.h); arm64 has only the plain one.
fn CInt mount_table(Statfs** mounts)
{
	$if env::X86_64:
		return sys_getmntinfo_inode64(mounts, MNT_NOWAIT);
	$else
		return sys_getmntinfo(mounts, MNT_NOWAIT);
	$endif
}

<* Local disks with their usage, one per device, copied into `allocator`. *>
fn Mount[]? read_mounts(Allocator allocator)
{
	Statfs* table;
	CInt count = mount_table(&table);
	if (count <= 0) return error::raise(error::BACKEND_FAILURE, error::Domain.MACH, 0, "getmntinfo returned no mounts")~;
	List{Mount} mounts;
	mounts.init(tmem);
	for (CInt i = 0; i < count; i++)
	{
		Statfs* entry = &table[i];
		String device = ((ZString)&entry.f_mntfromname).str_view();
		if (!device.starts_with("/dev/") || has_device(&mounts, device)) continue;
		ulong unit = entry.f_bsize;
		Bytes total = entry.f_blocks * unit;
		Bytes free = entry.f_bfree * unit;
		mounts.push({
			.device = device.copy(allocator),
			.mount_point = ((ZString)&entry.f_mntonname).str_view().copy(allocator),
			.fs_type = ((ZString)&entry.f_fstypename).str_view().copy(allocator),
			.total = total,
			.used = total - free,
			.available = entry.f_bavail * unit,
		});
	}
	return alloc::clone_slice(allocator, mounts.array_view());
}

fn bool has_device(List{Mount}* mounts, String device)
{
	foreach (&mount : mounts)
	{
		if (mount.device == device) return true;
	}
	return false;
}

<*
 Counters of every non-loopback AF_LINK entry of getifaddrs, in tmem. The
 counters are 32-bit (if_data); a wrap between samples gives one unknown rate.
*>
fn delta::NetCounters[]? read_interfaces()
{
	IfAddrs* list;
	if (sys_getifaddrs(&list) != 0) return unix::errno_fault("getifaddrs", libc::errno())~;
	defer sys_freeifaddrs(list);
	List{delta::NetCounters} counters;
	counters.init(tmem);
	for (IfAddrs* entry = list; entry != null; entry = entry.next)
	{
		if (entry.addr == null || (int)entry.addr.family != AF_LINK) continue;
		if ((entry.flags & IFF_LOOPBACK) != 0 || entry.data == null) continue;
		IfData* data = (IfData*)entry.data;
		counters.push({
			.name = ((ZString)entry.name).str_view().copy(tmem),
			.received = data.ifi_ibytes,
			.sent = data.ifi_obytes,
		});
	}
	return alloc::clone_slice(tmem, counters.array_view());
}

<* One reading of every process that can be listed; processes that exit mid-read are skipped. *>
fn sysinfo::ProcessSample[]? read_processes(MachBackend* backend, Duration elapsed, uint processors)
{
	CInt needed = proc_listpids(PROC_ALL_PIDS, 0, null, 0);
	if (needed <= 0) return error::raise(error::BACKEND_FAILURE, error::Domain.MACH, 0, "proc_listpids sizing failed")~;
	// pid_t is a 32-bit integer.
	CInt[] pids = alloc::new_array(tmem, CInt, (sz)needed / 4);
	CInt bytes = proc_listpids(PROC_ALL_PIDS, 0, pids.ptr, needed);
	if (bytes <= 0) return error::raise(error::BACKEND_FAILURE, error::Domain.MACH, 0, "proc_listpids failed")~;
	List{sysinfo::ProcessSample} samples;
	samples.init(tmem);
	for (sz i = 0; i < (sz)bytes / 4; i++)
	{
		if (pids[i] <= 0) continue;
		if (try reading = read_process(backend, (uint)pids[i], elapsed, processors))
		{
			samples.push(reading);
		}
	}
	return samples.array_view();
}

fn sysinfo::ProcessSample? read_process(MachBackend* backend, uint pid, Duration elapsed, uint processors)
{
	ProcBsdInfo bsd;
	if (proc_pidinfo((CInt)pid, PROC_PIDTBSDINFO, 0, &bsd, (CInt)@sizeof(bsd)) != (CInt)@sizeof(bsd))
	{
		return error::raise(error::UNAVAILABLE, error::Domain.MACH, 0, "process %d is gone", pid)~;
	}
	ProcTaskInfo task;
	// Another account's task info is refused; the process is still listed, without memory and CPU.
	bool has_task = proc_pidinfo((CInt)pid, PROC_PIDTASKINFO, 0, &task, (CInt)@sizeof(task)) == (CInt)@sizeof(task);
	ulong started = bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec;
	ulong nanoseconds = 0;
	Maybe{Percent} cpu = {};
	Maybe{Bytes} memory = {};
	if (has_task)
	{
		nanoseconds = to_nanoseconds(backend.timebase, task.pti_total_user + task.pti_total_system);
		memory = maybe::value(task.pti_resident_size);
		if (try earlier = delta::find_process(backend.previous_processes.array_view(), pid, started))
		{
			cpu = delta::process_percent(earlier.ticks, nanoseconds, NANOSECONDS_PER_SECOND, elapsed, processors);
		}
	}
	return {
		.process = {
			.pid = pid,
			.name = ((ZString)&bsd.pbi_comm).str_view().copy(tmem),
			.command = "",
			.user = user_of(bsd.pbi_uid),
			.cpu = cpu,
			.memory = memory,
		},
		// A process without task info keeps start time 0, which no real process has, so its next CPU share stays unknown.
		.ticks = { .pid = pid, .started = has_task ? started : 0, .ticks = nanoseconds },
	};
}

// Mach absolute-time ticks to nanoseconds (mach_timebase_info: ns = ticks * numer / denom).
fn ulong to_nanoseconds(TimebaseInfo timebase, ulong ticks) @inline => ticks * timebase.numer / timebase.denom;

<* The account name for `uid`, or its number when the account database does not name it. *>
fn String user_of(uint uid)
{
	PasswdHead* entry = (PasswdHead*)getpwuid(uid);
	if (entry == null) return string::tformat("%d", uid).copy(tmem);
	return entry.name.str_view().copy(tmem);
}

<* The machine's identity: host name, macOS version, kernel release, machine type, and uptime from kern.boottime. *>
fn Identity? read_identity(Allocator allocator)
{
	Identity identity;
	identity.hostname = (sysctl_text("kern.hostname") ?? "").copy(allocator);
	String version = sysctl_text("kern.osproductversion") ?? "";
	identity.os = (version.len == 0 ? "macOS" : string::tformat("macOS %s", version)).copy(allocator);
	identity.kernel = (sysctl_text("kern.osrelease") ?? "").copy(allocator);
	identity.arch = (sysctl_text("hw.machine") ?? "").copy(allocator);
	TimeVal boot;
	sysctl_read("kern.boottime", &boot, @sizeof(boot))!;
	identity.uptime = (Duration)(((long)sys_time(null) - boot.sec) * 1_000_000);
	return identity;
}

<* The value of a fixed-size sysctl into `buffer`; the size must match exactly. *>
fn void? sysctl_read(String name, void* buffer, usz size)
{
	usz length = size;
	if (sys_sysctlbyname(name.zstr_tcopy(), buffer, &length, null, 0) != 0)
	{
		return unix::errno_fault("sysctlbyname", libc::errno())~;
	}
	if (length != size) return error::raise(error::PROTOCOL, error::Domain.MACH, 0, "%s has %d bytes, expected %d", name, length, size)~;
}

<* A string sysctl, copied into tmem. *>
fn String? sysctl_text(String name)
{
	ZString key = name.zstr_tcopy();
	usz length = 0;
	if (sys_sysctlbyname(key, null, &length, null, 0) != 0) return unix::errno_fault("sysctlbyname", libc::errno())~;
	char[] buffer = alloc::new_array(tmem, char, (sz)length);
	if (sys_sysctlbyname(key, buffer.ptr, &length, null, 0) != 0) return unix::errno_fault("sysctlbyname", libc::errno())~;
	return ((ZString)buffer.ptr).str_view().copy(tmem);
}
