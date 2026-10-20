<*
 The three C functions the procfs backend calls that the standard library does
 not bind: uname(2), statvfs(3) and sysconf(3). Layouts are checked against the
 system headers (verified with gcc on the sandbox: sizeof utsname fields 65,
 sizeof struct statvfs 112, _SC_CLK_TCK 2); glibc and musl agree on LP64 Linux.
*>
module bleu::sysinfo::procfs @feat(LINUX);
import libc;

<* `struct utsname` (sys/utsname.h): six NUL-terminated fields of 65 bytes. *>
struct Utsname
{
	char[65] sysname;
	char[65] nodename;
	char[65] release;
	char[65] version;
	char[65] machine;
	char[65] domainname;
}

<* `struct statvfs` (sys/statvfs.h) for LP64 Linux: block counts are in units of `f_frsize`. *>
struct Statvfs
{
	ulong f_bsize;
	ulong f_frsize;
	ulong f_blocks;
	ulong f_bfree;
	ulong f_bavail;
	ulong f_files;
	ulong f_ffree;
	ulong f_favail;
	ulong f_fsid;
	ulong f_flag;
	ulong f_namemax;
	int[6] f_spare;
}

<* `_SC_CLK_TCK` from bits/confname.h: the clock of /proc/<pid>/stat times (USER_HZ). *>
const CInt SC_CLK_TCK = 2;

extern fn CInt sys_uname(Utsname* buffer) @cname("uname");
extern fn CInt sys_statvfs(ZString path, Statvfs* buffer) @cname("statvfs");
extern fn CLong sys_sysconf(CInt name) @cname("sysconf");