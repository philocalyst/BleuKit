<*
 The Windows readers. Each returns plain values with temporaries in tmem; any
 strings that outlive the sample are copied into the allocator given.
*>
module bleu::sysinfo::win @feat(WIN32);
import std::time, std::collections::list, std::collections::maybe, bleu::error, bleu::sysinfo, bleu::sysinfo::delta, bleu::win::errors, bleu::win::text;

<* Text of a NUL-terminated UTF-16 buffer, copied into tmem. "" when empty or not text. *>
fn String wide_text(Char16[] units)
{
	usz length = 0;
	while (length < units.len && units[length] != 0) length++;
	return text::from_wide_units(tmem, units[:length]) ?? "";
}

<* A fresh NtQuerySystemInformation result of `cls`, grown until it fits. *>
fn char[]? system_information(uint cls, uint first_size)
{
	uint size = first_size;
	for (int attempt = 0; attempt < MAX_QUERY_ATTEMPTS; attempt++)
	{
		char[] buffer = alloc::new_array(tmem, char, (sz)size);
		uint returned = 0;
		int status    = sys_nt_query_system_information(cls, buffer.ptr, size, &returned);
		if (status == 0) return buffer[:returned];
		if ((uint)status != STATUS_INFO_LENGTH_MISMATCH) return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.WIN32,
			status,
			"NtQuerySystemInformation(%d) failed",
			cls
		)~;
		size = returned > size ? returned : size * 2;
	}
	return error::raise(
		error::BACKEND_FAILURE,
		error::Domain.WIN32,
		0,
		"NtQuerySystemInformation(%d) kept growing",
		cls
	)~;
}

const int MAX_QUERY_ATTEMPTS       = 8;
const uint INITIAL_PROCESS_QUERY   = 1 << 18;
const uint INITIAL_PROCESSOR_QUERY = 1 << 10;

<*
 Per-processor times: busy is kernel minus idle (kernel already counts idle) plus user.
 Aggregate first (index -1), then each processor, all in 100 ns ticks.
*>
fn delta::CpuLine[]? processor_lines()
{
	char[] buffer              = system_information(SYSTEM_PROCESSOR_PERFORMANCE_CLASS, INITIAL_PROCESSOR_QUERY)!;
	ProcessorPerformance* rows = (ProcessorPerformance*)buffer.ptr;
	usz count                  = buffer.len / @sizeof(rows[0]);
	delta::CpuLine[] lines     = alloc::new_array(tmem, delta::CpuLine, (sz)count + 1);
	delta::Ticks total         = { .busy = 0, .total = 0 };
	for (usz i = 0; i < count; i++)
	{
		ProcessorPerformance row = rows[i];
		ulong busy               = (ulong)(row.kernel - row.idle) + (ulong)row.user;
		ulong all                = (ulong)row.kernel + (ulong)row.user;
		lines[i + 1] = { .index = (int)i, .ticks = { .busy = busy, .total = all } };
		total.busy += busy;
		total.total += all;
	}
	lines[0] = { .index = -1, .ticks = total };
	return lines;
}

<* Current clock per processor in MHz, empty where the driver reports 0 or the call is refused. *>
fn void processor_frequencies(sysinfo::Cpu* cpu)
{
	usz count = cpu.cores.len;
	if (count == 0) return;
	ProcessorPowerInformation[] infos = alloc::new_array(tmem, ProcessorPowerInformation, (sz)count);
	int status = sys_call_nt_power_information(
		PROCESSOR_INFORMATION_LEVEL,
		null,
		0,
		infos.ptr,
		(uint)(count * @sizeof(infos[0]))
	);
	if (status != 0) return;
	foreach (i, &core : cpu.cores)
	{
		if (infos[i].current_mhz != 0) core.frequency = maybe::value((Mhz)infos[i].current_mhz);
	}
}

<* Physical memory from GlobalMemoryStatusEx; swap is the commit limit beyond physical memory. *>
fn Memory? memory_figures()
{
	MemoryStatusEx status;
	status.length = @sizeof(status);
	if (sys_global_memory_status_ex(&status) == 0) return errors::raise_last("GlobalMemoryStatusEx")~;
	ulong available = status.avail_phys;
	return {
		.total = status.total_phys,
		.used = status.total_phys - available,
		.available = available,
		.swap_total = sysinfo::sub_or_zero(status.total_page_file, status.total_phys),
		.swap_used = sysinfo::sub_or_zero(
			status.total_page_file - status.avail_page_file,
			status.total_phys - status.avail_phys
		),
	};
}

<*
 Local fixed volumes with their first mount path and usage. Volumes without a
 mount path, and removable or network drives, are left out.
*>
fn Mount[]? read_mounts(Allocator allocator)
{
	List{Mount} mounts;
	mounts.init(tmem);
	Char16[MAX_PATH_UNITS] volume;
	void* finder = sys_find_first_volume(&volume[0], MAX_PATH_UNITS);
	if ((iptr)finder == -1) return errors::raise_last("FindFirstVolumeW")~;
	defer (void)sys_find_volume_close(finder);
	do
	{
		if (try mount = volume_mount(volume[..], allocator)) mounts.push(mount);
	} while (sys_find_next_volume(finder, &volume[0], MAX_PATH_UNITS) != 0);
	return alloc::clone_slice(allocator, mounts.array_view());
}

fn Mount? volume_mount(Char16[] volume, Allocator allocator)
{
	Char16[MAX_PATH_UNITS] paths;
	uint returned = 0;
	if (sys_get_volume_path_names(&volume[0], &paths[0], MAX_PATH_UNITS, &returned) == 0) return NOT_FOUND~;
	String mount_point = wide_text(paths[..]);
	if (mount_point.len == 0 || sys_get_drive_type(&paths[0]) != DRIVE_FIXED_TYPE) return NOT_FOUND~;
	ulong available = 0;
	ulong total     = 0;
	ulong free      = 0;
	if (sys_get_disk_free_space_ex(&paths[0], &available, &total, &free) == 0) return NOT_FOUND~;
	Char16[64] fs_name;
	String fs_type = "";
	if (sys_get_volume_information(&paths[0], null, 0, null, null, null, &fs_name[0], 64) != 0)
	{
		fs_type = wide_text(fs_name[..]).copy(allocator);
	}
	return {
		.device = wide_text(volume[..])
		.copy(
			allocator
		), .mount_point = mount_point.copy(
			allocator
		), .fs_type = fs_type, .total = total, .used = total - free, .available = available, };
}

<*
 Counters of every interface except software loopback, from GetIfTable2 (64-bit
 octet counters). The name is the interface's alias, such as "Ethernet".
*>
fn delta::NetCounters[]? read_interfaces()
{
	void* table = null;
	uint status = sys_get_if_table_2(&table);
	if (status != 0 || table == null) return error::raise(
		error::BACKEND_FAILURE,
		error::Domain.WIN32,
		(int)status,
		"GetIfTable2 failed"
	)~;
	defer sys_free_mib_table(table);
	uint entries = *(uint*)table;
	List{delta::NetCounters} counters;
	counters.init(tmem);
	for (uint i = 0; i < entries; i++)
	{
		// MIB_IF_TABLE2 holds the rows after its 4-byte count, padded to the rows' 8-byte alignment.
		MibIfRow2* row = &((MibIfRow2*)&((char*)table)[8])[i];
		if (row.type == IF_TYPE_SOFTWARE_LOOPBACK) continue;
		counters.push({ .name = wide_text(row.alias_name[..])
			.copy(tmem), .received = row.in_octets, .sent = row.out_octets });
	}
	return alloc::clone_slice(tmem, counters.array_view());
}

<* Uptime from GetTickCount64 (milliseconds since boot). *>
fn Duration uptime() @inline => (Duration)(sys_get_tick_count_64() * 1000);