<*
 Machine health as plain data: processor load, memory, disks, network rates,
 temperatures, the busiest processes and the identity of the machine.

 Values the platform cannot give, or cannot give yet, are `Maybe` empties, never
 zero: a rate on the first sample is unknown, not zero, and so is a clock
 frequency on a machine that does not report one. Strings that a platform
 does not provide are "" and say so in their field comment.
*>
module bleu::sysinfo;
import std::time, std::collections::maybe, bleu::unit, bleu::operation;

<* A percentage on the scale people read: 0.0 .. 100.0 per logical processor, so a process may exceed 100. *>
typedef Percent = float;

<* A count of bytes. *>
typedef Bytes = ulong;

<* A throughput in bytes per second. *>
typedef BytesPerSecond = ulong;

<* A clock frequency in megahertz. *>
typedef Mhz = uint;

<* A load average: runnable tasks averaged over one, five and fifteen minutes. *>
typedef LoadAverage = float;

<* One logical processor. `name` is the kernel's name for it ("cpu0"), or its index as text elsewhere. *>
struct CpuCore
{
	String name;
	Maybe{Percent} usage; // empty until two samples exist to compare
	Maybe{Mhz} frequency; // empty when the platform does not report a per-core clock
}

<* The processors as a whole. *>
struct Cpu
{
	String model; // marketing name of the processor, "" when the platform does not say
	Maybe{Percent} usage; // all logical processors together; empty until two samples exist
	CpuCore[] cores;
	LoadAverage[3] load_average; // one, five and fifteen minutes
}

<* Physical and swap memory. `used` is `total - available`, the same rule on every platform. *>
struct Memory
{
	Bytes total;
	Bytes used;
	Bytes available; // what applications can take without swapping
	Maybe{Bytes} cache; // file-backed and reclaimable memory; empty where the platform does not separate it
	Bytes swap_total;
	Bytes swap_used;
}

<* One mounted local disk volume. *>
struct Mount
{
	String device; // "/dev/vda", "C:" ... (the source the kernel reports)
	String mount_point; // "/", "C:\" ...
	String fs_type; // "ext4", "apfs", "NTFS"; "" when the platform does not say
	Bytes total;
	Bytes used;
	Bytes available; // free to an unprivileged user
}

<* One network interface. Loopback is not reported. *>
struct NetInterface
{
	String name;
	Maybe{BytesPerSecond} receive;
	Maybe{BytesPerSecond} transmit;
}

<* One temperature reading in degrees Celsius. `name` says where it comes from. *>
struct Temperature
{
	String name;
	Celsius value;
}

<* One process. `command` and `user` are "" when they cannot be read (another user's process, a kernel thread). *>
struct Process
{
	uint pid;
	String name; // short name: the kernel's command name or the executable name
	String command; // full command line
	String user; // account name, or the numeric id when no name is known
	Maybe{Percent} cpu; // share of one logical processor since the previous sample
	Maybe{Bytes} memory; // resident set size
}

<* What the machine is. Changes only through `uptime`, which is also why it is re-published every sample. *>
struct Identity
{
	String hostname;
	String os; // "Ubuntu 24.04.1 LTS", "macOS 15.1", "Windows 11 Pro"
	String kernel; // release of the kernel: "6.8.0-45-generic", "24.1.0", "10.0.26100"
	String arch; // machine architecture: "x86_64", "arm64", "aarch64"
	Duration uptime; // time since boot
}

<*
 The whole picture, published as one snapshot per sample. Lists are sorted:
 mounts and interfaces by name, temperatures by source, processes by CPU use
 (busiest first, then by pid).
*>
struct State
{
	Cpu cpu;
	Memory memory;
	Mount[] mounts;
	NetInterface[] interfaces;
	Temperature[] temperatures;
	Process[] processes;
	Identity identity;
}

<*
 Things a backend may not provide. `Availability` says whether each works here
 and, if not, why.
*>
enum Cap : char
{
	CPU_USAGE,      // total and per-core usage
	CPU_FREQUENCY,  // per-core clock
	TEMPERATURES,   // sensor readings
	NETWORK_RATES,  // receive and transmit rates
	PROCESS_COMMAND, // full command lines of processes
	PROCESS_USER,   // account of each process
	PROCESS_KILL,   // ending another process
}

<* Transient facts: a volume or an interface came or went. Re-read the state for the details. *>
enum EventKind : char
{
	MOUNT_ADDED,
	MOUNT_REMOVED,
	INTERFACE_ADDED,
	INTERFACE_REMOVED,
}

<* A transient. `name` is the mount point or the interface name. *>
struct Event
{
	EventKind kind;
	String name;
}

<*
 How hard to end a process. `TERMINATE` asks it to stop (SIGTERM on Unix; on
 Windows the process is ended at once, since the platform has no polite form).
 `FORCE` cannot be caught or ignored (SIGKILL; TerminateProcess on Windows).
*>
enum KillMode : char
{
	TERMINATE,
	FORCE,
}

<* What a successful kill reports: the process that was signalled and how. *>
struct KillReceipt
{
	uint pid;
	KillMode mode;
}

<*
 A request for the worker thread. The only command is a process kill, so the
 type is not a sum: the worker completes `operation` exactly once.
*>
struct Command
{
	uint pid;
	KillMode mode;
	Operation{KillReceipt}* operation;
}

<* Which concrete mechanism provides the data. *>
enum Backend : char
{
	AUTO,   // tries every backend of the platform in priority order
	PROCFS, // Linux: /proc and /sys
	MACH,   // macOS: host_* and sysctl, libproc, getifaddrs, statfs
	WIN32,  // Windows: NtQuerySystemInformation, GetSystemTimes, GlobalMemoryStatusEx ...
}
