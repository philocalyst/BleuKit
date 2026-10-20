<*
 Bindings for the macOS calls the Mach backend makes: host_* statistics, the
 kernel's processor load, sysctl, getifaddrs, getmntinfo, libproc and the time
 base. Layouts are the 64-bit ones of the XNU sources the project cites:
 osfmk/mach/processor_info.h   processor_cpu_load_info, PROCESSOR_CPU_LOAD_INFO = 2
 osfmk/mach/machine.h          CPU_STATE_USER 0, SYSTEM 1, IDLE 2, NICE 3
 osfmk/mach/host_info.h        HOST_CPU_LOAD_INFO 3, HOST_VM_INFO64 4
 osfmk/mach/vm_statistics.h    struct vm_statistics64 (160 bytes)
 bsd/sys/mount.h               struct statfs with __DARWIN_64_BIT_INO_T (the macro body)
 bsd/net/if_var.h              struct if_data (32-bit counters, as getifaddrs gives)
 bsd/sys/proc_info.h           proc_bsdinfo, proc_taskinfo, PROC_* flavours
 bsd/sys/sysctl.h              struct xsw_usage (vm.swapusage)
 bsd/sys/socket.h              AF_LINK 18
 bsd/net/if.h                  IFF_LOOPBACK 0x8
 Every constant and layout was read from those headers; nothing here has run on a Mac.
*>
module bleu::sysinfo::mach @feat(DARWIN);

const uint PROCESSOR_CPU_LOAD_INFO = 2;
const uint CPU_STATE_USER          = 0;
const uint CPU_STATE_SYSTEM        = 1;
const uint CPU_STATE_IDLE          = 2;
const uint CPU_STATE_NICE          = 3;
const CInt HOST_CPU_LOAD_INFO      = 3;
const CInt HOST_VM_INFO64          = 4;
const CInt PROC_ALL_PIDS           = 1;
const CInt PROC_PIDTBSDINFO        = 3;
const CInt PROC_PIDTASKINFO        = 4;
const int AF_LINK                  = 18;
const uint IFF_LOOPBACK            = 0x8;
const uint MFSTYPENAMELEN          = 16;
const uint MAXPATHLEN              = 1024;
const uint MAXCOMLEN               = 16;
const CInt MNT_NOWAIT              = 2;
const ulong NANOSECONDS_PER_SECOND = 1_000_000_000;

<* `processor_cpu_load_info`: ticks per CPU_STATE_* index, for one processor. *>
struct ProcessorLoad
{
	uint[4] cpu_ticks;
}

<* `struct vm_statistics64` (160 bytes): page counts are 32-bit, lifetime counters 64-bit. *>
struct VmStatistics64
{
	uint free_count;
	uint active_count;
	uint inactive_count;
	uint wire_count;
	ulong zero_fill_count;
	ulong reactivations;
	ulong pageins;
	ulong pageouts;
	ulong faults;
	ulong cow_faults;
	ulong lookups;
	ulong hits;
	ulong purges;
	uint purgeable_count;
	uint speculative_count;
	ulong decompressions;
	ulong compressions;
	ulong swapins;
	ulong swapouts;
	uint compressor_page_count;
	uint throttled_count;
	uint external_page_count;
	uint internal_page_count;
	ulong total_uncompressed_pages_in_compressor;
	ulong swapped_count;
}

<* `struct xsw_usage` (vm.swapusage), 32 bytes. *>
struct XswUsage
{
	ulong total;
	ulong avail;
	ulong used;
	uint pagesize;
	int encrypted;
}

<* `struct timeval` as the kernel returns kern.boottime on LP64: seconds, then a 32-bit microsecond count. *>
struct TimeVal
{
	long sec;
	int usec;
}

<* `struct statfs` in its 64-bit-inode form (the __DARWIN_STRUCT_STATFS64 body in bsd/sys/mount.h). *>
struct Statfs
{
	uint f_bsize;
	int f_iosize;
	ulong f_blocks;
	ulong f_bfree;
	ulong f_bavail;
	ulong f_files;
	ulong f_ffree;
	int[2] f_fsid;
	uint f_owner;
	uint f_type;
	uint f_flags;
	uint f_fssubtype;
	char[MFSTYPENAMELEN] f_fstypename;
	char[MAXPATHLEN] f_mntonname;
	char[MAXPATHLEN] f_mntfromname;
	uint f_flags_ext;
	uint[7] f_reserved;
}

<* The leading fields of `struct if_data` (bsd/net/if_var.h): the octet and packet counters. *>
struct IfData
{
	char ifi_type;
	char ifi_typelen;
	char ifi_physical;
	char ifi_addrlen;
	char ifi_hdrlen;
	char ifi_recvquota;
	char ifi_xmitquota;
	char ifi_unused1;
	uint ifi_mtu;
	uint ifi_metric;
	uint ifi_baudrate;
	uint ifi_ipackets;
	uint ifi_ierrors;
	uint ifi_opackets;
	uint ifi_oerrors;
	uint ifi_collisions;
	uint ifi_ibytes;
	uint ifi_obytes;
}

<* `struct ifaddrs` (ifaddrs.h): one entry per address; AF_LINK entries carry `if_data`. *>
struct IfAddrs
{
	IfAddrs* next;
	ZString name;
	uint flags;
	SockAddr* addr;
	void* netmask;
	void* broadaddr;
	void* data;
}

<* The first two bytes of every `struct sockaddr`. *>
struct SockAddr
{
	char length;
	char family;
}

<* `struct proc_bsdinfo`: the fields the service reads; `pbi_comm` is the short command name. *>
struct ProcBsdInfo
{
	uint pbi_flags;
	uint pbi_status;
	uint pbi_xstatus;
	uint pbi_pid;
	uint pbi_ppid;
	uint pbi_uid;
	uint pbi_gid;
	uint pbi_ruid;
	uint pbi_rgid;
	uint pbi_svuid;
	uint pbi_svgid;
	uint rfu_1;
	char[MAXCOMLEN] pbi_comm;
	char[2 * MAXCOMLEN] pbi_name;
	uint pbi_nfiles;
	uint pbi_pgid;
	uint pbi_pjobc;
	uint e_tdev;
	uint e_tpgid;
	int pbi_nice;
	ulong pbi_start_tvsec;
	ulong pbi_start_tvusec;
}

<* `struct proc_taskinfo`: resident size, and CPU time in Mach absolute-time units. *>
struct ProcTaskInfo
{
	ulong pti_virtual_size;
	ulong pti_resident_size;
	ulong pti_total_user;
	ulong pti_total_system;
	ulong pti_threads_user;
	ulong pti_threads_system;
	int pti_policy;
	int pti_faults;
	int pti_pageins;
	int pti_cow_faults;
	int pti_messages_sent;
	int pti_messages_received;
	int pti_syscalls_mach;
	int pti_syscalls_unix;
	int pti_csw;
	int pti_threadnum;
	int pti_numrunning;
	int pti_priority;
}

<* `mach_timebase_info_data_t`: nanoseconds = ticks * numer / denom. *>
struct TimebaseInfo
{
	uint numer;
	uint denom;
}

<* `struct passwd` starts with `pw_name`, the only field the service reads. *>
struct PasswdHead
{
	ZString name;
}

extern uint mach_task_self_;
extern fn uint mach_host_self() @cname("mach_host_self");
extern fn CInt host_processor_info(
	uint host,
	CInt flavor,
	uint* cpu_count,
	ProcessorLoad** info,
	uint* info_count
) @cname("host_processor_info");
extern fn CInt host_statistics64(uint host, CInt flavor, VmStatistics64* info, uint* count) @cname("host_statistics64");
extern fn CInt vm_deallocate(uint task, ulong address, ulong size) @cname("vm_deallocate");
extern fn CInt mach_timebase_info(TimebaseInfo* info) @cname("mach_timebase_info");
extern fn CInt sys_sysctlbyname(
	ZString name,
	void* old,
	usz* old_length,
	void* new,
	usz new_length
) @cname("sysctlbyname");
extern fn CInt sys_getloadavg(double* averages, CInt count) @cname("getloadavg");
extern fn CInt sys_getpagesize() @cname("getpagesize");
extern fn CInt sys_getifaddrs(IfAddrs** list) @cname("getifaddrs");
extern fn void sys_freeifaddrs(IfAddrs* list) @cname("freeifaddrs");
extern fn CInt sys_getmntinfo_inode64(Statfs** mounts, CInt flags) @cname("getmntinfo$INODE64");
extern fn CInt sys_getmntinfo(Statfs** mounts, CInt flags) @cname("getmntinfo");
extern fn CInt proc_listpids(CInt kind, uint typeinfo, void* buffer, CInt buffer_size) @cname("proc_listpids");
extern fn CInt proc_pidinfo(
	CInt pid,
	CInt flavor,
	ulong argument,
	void* buffer,
	CInt buffer_size
) @cname("proc_pidinfo");
extern fn void* getpwuid(uint uid) @cname("getpwuid");
extern fn long sys_time(void* out) @cname("time");