# bleu_sysinfo: implementation notes

Spec: `docs/research/apps_sysinfo_secrets_appearance.md`, section "sysinfo" (part B).

## Deviations from the research

* **Per-core frequency is in v1** on Linux and Windows. The research cut deferred it; the
  implementation request kept it. macOS has no public per-core clock, so it is `Not done`.
* **Disk I/O rates are not implemented.** The v1 list in the request names disk mounts and
  usage only.
* **Load average** is `Maybe` per field: Windows has none, and an empty value must not read as zero.
* **Bytes and BytesPerSecond are aliases of `ulong`**, not distinct typedefs: sizes are summed and
  subtracted everywhere, and distinct types forced casts at every step.
* **Windows per-core times** come from `NtQuerySystemInformation(SystemProcessorPerformanceInformation)`
  (class 8, sources below), not `GetSystemTimes`. Kernel time includes idle, so busy is kernel minus
  idle plus user. The processor count comes from the same result.
* **Windows memory** uses `GlobalMemoryStatusEx`. Swap is the commit limit beyond physical memory, and
  used swap is commit total beyond physical use. sysinfo 0.33.1 `windows/system.rs` lines 186-198 reach
  the same figures through `GetPerformanceInfo`.
* **macOS available memory** follows sysinfo 0.33.1 (`unix/apple/system.rs` 189-205): free, inactive and
  purgeable pages, less compressor pages. Not checked on a Mac.

## Sources read in this session

* XNU (`apple-oss-distributions/xnu`, main): `osfmk/mach/processor_info.h` (PROCESSOR_CPU_LOAD_INFO 2),
  `osfmk/mach/machine.h` (CPU_STATE_* 0..3), `osfmk/mach/host_info.h` (HOST_CPU_LOAD_INFO 3,
  HOST_VM_INFO64 4), `osfmk/mach/vm_statistics.h` (vm_statistics64), `bsd/sys/mount.h`
  (statfs, MFSTYPENAMELEN 16), `bsd/net/if_var.h` (if_data), `bsd/sys/proc_info.h`
  (proc_bsdinfo, proc_taskinfo, PROC_* flavours), `bsd/sys/sysctl.h` (xsw_usage),
  `bsd/sys/socket.h` (AF_LINK 18), `bsd/sys/syslimits.h` (PATH_MAX 1024), `bsd/sys/cdefs.h`.
* Wine mirror (`wine-mirror/wine`, master): `include/netioapi.h` (MIB_IF_ROW2, MIB_IF_TABLE2),
  `include/winnt.h` (OSVERSIONINFOW, PROCESSOR_ARCHITECTURE_*), `include/winbase.h` (DRIVE_FIXED 3),
  `include/ipifcons.h` (IF_TYPE_SOFTWARE_LOOPBACK 24).
* ReactOS (`reactos/reactos`, master): `sdk/include/ndk/extypes.h` (NtQuerySystemInformation classes
  5 and 8).
* ntapi 0.4.1 (`static.crates.io`): `src/ntexapi.rs` SYSTEM_PROCESS_INFORMATION field order.
* sysinfo 0.33.1 (`static.crates.io`): `src/windows/cpu.rs` 484-505 (CallNtPowerInformation,
  PROCESSOR_POWER_INFORMATION), `src/windows/system.rs` 186-198 (swap), `src/unix/apple/system.rs`
  (memory rule, cited above).
* glibc headers and gcc on the sandbox: `_SC_CLK_TCK` = 2 (`bits/confname.h`, verified by running
  `sysconf`), `struct utsname` fields of 65 bytes, `sizeof(struct statvfs)` = 112.
* Linux kernel text formats: `/proc/stat`, `/proc/meminfo`, `/proc/loadavg`, `/proc/uptime`,
  `/proc/net/dev`, `/proc/mounts`, `/proc/<pid>/stat|status|cmdline`, `/etc/os-release`, `/etc/passwd`:
  captured from this sandbox into `libs/bleu_sysinfo.c3l/fixtures/`.

## Not checked, marked in code

* `getmntinfo$INODE64` (x86-64 only): the symbol name follows the header macro; not linked.
* `struct ifaddrs` field order on Darwin and `struct passwd` (`pw_name` first): not in the fetched
  headers; the layout is the usual BSD one.
* `RTL_OSVERSIONINFOW` and `MEMORYSTATUSEX` field order: matches winnt.h and the Learn page cited in the research.
* `PROCESSOR_POWER_INFORMATION` and the power level 11: sysinfo's use; Learn not fetched in this session.
* `kern.osproductversion`, `machdep.cpu.brand_string` on Apple Silicon: not verified.
