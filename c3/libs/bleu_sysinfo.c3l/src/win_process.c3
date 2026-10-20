<*
 The Windows process list (NtQuerySystemInformation, SystemProcessInformation)
 and the owner of each process. A process whose owner cannot be opened is
 listed with an empty owner, not dropped.
*>
module bleu::sysinfo::win @feat(WIN32);
import std::collections::list, std::collections::maybe, std::os::win32, std::time, bleu::error, bleu::sysinfo, bleu::sysinfo::delta, bleu::win::registry, bleu::win::text;

<* Ticks of the process clock per second: CPU times are in 100 ns units. *>
const ulong WINDOWS_TICKS_PER_SECOND = 10_000_000;

<* Owner account of `pid` as "DOMAIN\name", or "" when it cannot be read without more rights. *>
fn String process_owner(uint pid)
{
	void* process = sys_open_process(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
	if (process == null) return "";
	defer (void)win32::closeHandle(process);
	void* token = null;
	if (sys_open_process_token(process, TOKEN_QUERY, &token) == 0) return "";
	defer (void)win32::closeHandle(token);
	char[TOKEN_INFORMATION_CAPACITY] info;
	uint returned = 0;
	if (sys_get_token_information(
		token,
		TOKEN_USER_CLASS,
		&info[0],
		TOKEN_INFORMATION_CAPACITY,
		&returned
	) == 0) return "";
	TokenUser* user  = (TokenUser*)&info[0];
	Char16[ACCOUNT_NAME_UNITS] name;
	Char16[ACCOUNT_NAME_UNITS] domain;
	uint name_size   = ACCOUNT_NAME_UNITS;
	uint domain_size = ACCOUNT_NAME_UNITS;
	uint kind        = 0;
	if (sys_lookup_account_sid(null, user.sid, &name[0], &name_size, &domain[0], &domain_size, &kind) == 0) return "";
	String account   = wide_text(name[..]);
	String authority = wide_text(domain[..]);
	if (authority.len == 0) return account.copy(tmem);
	return string::tformat("%s\\%s", authority, account).copy(tmem);
}

const usz TOKEN_INFORMATION_CAPACITY = 256;
const usz ACCOUNT_NAME_UNITS         = 256;

<* Every process, in tmem, with the counters the next sample needs. *>
fn sysinfo::ProcessSample[]? read_processes(WinBackend* backend, Duration elapsed, uint processors)
{
	char[] buffer = system_information(SYSTEM_PROCESS_INFORMATION_CLASS, INITIAL_PROCESS_QUERY)!;
	List{sysinfo::ProcessSample} samples;
	samples.init(tmem);
	SystemProcessInformation sizing;
	usz offset = 0;
	while (offset + @sizeof(sizing) <= buffer.len)
	{
		SystemProcessInformation* entry = (SystemProcessInformation*)&buffer[offset];
		if (try reading = process_sample(backend, entry, elapsed, processors))
		{
			samples.push(reading);
		}
		if (entry.next_entry_offset == 0) break;
		offset += entry.next_entry_offset;
	}
	return samples.array_view();
}

fn sysinfo::ProcessSample? process_sample(
	WinBackend* backend,
	SystemProcessInformation* entry,
	Duration elapsed,
	uint processors
)
{
	uint pid    = (uint)entry.process_id;
	String name = "";
	if (entry.image_name.buffer != null)
	{
		name = wide_text(entry.image_name.buffer[:entry.image_name.length / 2]);
	}
	else if (pid == 0)
	{
		name = "System Idle Process";
	}
	ulong ticks        = (ulong)(entry.kernel_time + entry.user_time);
	ulong started      = (ulong)entry.create_time;
	Maybe{Percent} cpu = { };
	if (try earlier = delta::find_process(backend.previous_processes.array_view(), pid, started))
	{
		cpu = delta::process_percent(earlier.ticks, ticks, WINDOWS_TICKS_PER_SECOND, elapsed, processors);
	}
	return {
		.process = {
			.pid = pid,
			.name = name,
			.command = "",
			.user = process_owner(pid),
			.cpu = cpu,
			.memory = maybe::value((Bytes)entry.working_set_size),
		},
		.ticks = { .pid = pid, .started = started, .ticks = ticks },
	};
}

<* Computer name (the DNS host name, without domain), from GetComputerNameExW. *>
fn String computer_name()
{
	Char16[COMPUTER_NAME_UNITS] buffer;
	uint size = COMPUTER_NAME_UNITS;
	if (sys_get_computer_name(COMPUTER_NAME_PHYSICAL_DNS_HOSTNAME, &buffer[0], &size) == 0) return "";
	return wide_text(buffer[..]);
}

const usz COMPUTER_NAME_UNITS = 256;

<*
 The product name from the registry. Windows 11 keeps "Windows 10" in
 ProductName on machines upgraded from it, so the build number decides.
*>
fn String os_name()
{
	if (try key = registry::open(
		registry::Hive.LOCAL_MACHINE,
		"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion",
		registry::View.NATIVE,
		registry::KEY_READ
	))
	{
		defer key.close();
		String product = key.string(tmem, "ProductName") ?? "Windows";
		uint build     = (key.string(tmem, "CurrentBuild") ?? "").to_uint() ?? 0;
		if (build >= FIRST_WINDOWS_11_BUILD && product.starts_with("Windows 10"))
		{
			return string::tformat("Windows 11%s", product[10:product.len - 10]);
		}
		return product;
	}
	return "Windows";
}

const uint FIRST_WINDOWS_11_BUILD = 22000;

// Processor model string the firmware reports for logical processor 0.
fn String cpu_model()
{
	if (try key = registry::open(
		registry::Hive.LOCAL_MACHINE,
		"HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",
		registry::View.NATIVE,
		registry::KEY_READ
	))
	{
		defer key.close();
		return key.string(tmem, "ProcessorNameString") ?? "";
	}
	return "";
}

<* Machine architecture from GetNativeSystemInfo (the processor architecture is its first field). *>
fn String native_architecture()
{
	char[SYSTEM_INFO_CAPACITY] info;
	sys_get_native_system_info(&info[0]);
	ushort architecture = *(ushort*)&info[0];
	switch (architecture)
	{
		case ARCH_AMD64: return "x86_64";
		case ARCH_ARM64: return "aarch64";
		case ARCH_INTEL: return "x86";
		default: return "unknown";
	}
}

// SYSTEM_INFO is 48 bytes on 64-bit Windows; the buffer is larger than any layout it is read from.
const usz SYSTEM_INFO_CAPACITY = 64;

<* The machine's identity. Kernel is the Windows version as "major.minor.build". *>
fn Identity? read_identity(Allocator allocator)
{
	Identity identity;
	identity.hostname = computer_name().copy(allocator);
	identity.os = os_name().copy(allocator);
	OsVersionInfoW version;
	version.size = @sizeof(version);
	if (sys_rtl_get_version(
		&version
	) != 0) return error::raise(error::BACKEND_FAILURE, error::Domain.WIN32, 0, "RtlGetVersion failed")~;
	identity.kernel = string::tformat("%d.%d.%d", version.major, version.minor, version.build).copy(allocator);
	identity.arch = native_architecture();
	identity.uptime = uptime();
	return identity;
}