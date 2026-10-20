<*
 Win32 and native (ntdll) calls the Windows backend makes, with the layouts
 read from primary sources. Sources, each read in this session:
 winbase.h / winnt.h (Wine mirror, Win32 headers): DRIVE_FIXED 3,
 INVALID_HANDLE_VALUE, PROCESSOR_ARCHITECTURE_* (winnt.h 697, 706, 709),
 OSVERSIONINFOW (winnt.h 6558, RTL_OSVERSIONINFOW alias)
 netioapi.h (Wine mirror): MIB_IF_ROW2 (1352 bytes, OutOctets at 1280) and
 MIB_IF_TABLE2 (NumEntries, then rows at offset 8 for the 8-byte row alignment)
 ipifcons.h (Wine mirror): IF_TYPE_SOFTWARE_LOOPBACK 24
 ntapi 0.4.1 ntexapi.rs (crates.io): SYSTEM_PROCESS_INFORMATION field order
 ReactOS sdk/include/ndk/extypes.h: NtQuerySystemInformation classes 5
 (SystemProcessInformation) and 8 (SystemProcessorPerformanceInformation)
 sysinfo 0.33.1 windows/cpu.rs 484-505: CallNtPowerInformation with
 PROCESSOR_POWER_INFORMATION (power level ProcessorInformation = 11)
 GlobalMemoryStatusEx: Microsoft Learn MEMORYSTATUSEX (fetched in the research)
 Compiled for Windows only; nothing here has run.
*>
module bleu::sysinfo::win @feat(WIN32);

const uint PROCESS_QUERY_LIMITED_INFORMATION   = 0x1000;
const uint TOKEN_QUERY                         = 0x0008;
const uint TOKEN_USER_CLASS                    = 1;
const uint SYSTEM_PROCESS_INFORMATION_CLASS    = 5;
const uint SYSTEM_PROCESSOR_PERFORMANCE_CLASS  = 8;
const uint PROCESSOR_INFORMATION_LEVEL         = 11;
const uint STATUS_INFO_LENGTH_MISMATCH         = 0xC0000004;
const uint COMPUTER_NAME_PHYSICAL_DNS_HOSTNAME = 5;
const uint DRIVE_FIXED_TYPE                    = 3;
const uint IF_TYPE_SOFTWARE_LOOPBACK           = 24;
const ushort ARCH_INTEL                        = 0;
const ushort ARCH_AMD64                        = 9;
const ushort ARCH_ARM64                        = 12;
const uint ERROR_INVALID_PARAMETER             = 87;
const usz MAX_PATH_UNITS                       = 260;

<* MEMORYSTATUSEX (Learn: GlobalMemoryStatusEx). *>
struct MemoryStatusEx
{
	uint length;
	uint memory_load;
	ulong total_phys;
	ulong avail_phys;
	ulong total_page_file;
	ulong avail_page_file;
	ulong total_virtual;
	ulong avail_virtual;
	ulong avail_extended_virtual;
}

<* SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION: 100 ns units; kernel time includes idle time. 48 bytes. *>
struct ProcessorPerformance
{
	long idle;
	long kernel;
	long user;
	long dpc;
	long interrupt;
	uint interrupt_count;
}

<* PROCESSOR_POWER_INFORMATION: clocks in MHz. 24 bytes. *>
struct ProcessorPowerInformation
{
	uint number;
	uint max_mhz;
	uint current_mhz;
	uint mhz_limit;
	uint max_idle_state;
	uint current_idle_state;
}

<* UNICODE_STRING. *>
struct UnicodeString
{
	ushort length;
	ushort maximum_length;
	Char16* buffer;
}

<*
 The leading fields of SYSTEM_PROCESS_INFORMATION (x64 layout, natural alignment).
 Records follow each other at `next_entry_offset` bytes; the last has 0.
*>
struct SystemProcessInformation
{
	uint next_entry_offset;
	uint thread_count;
	long working_set_private;
	uint hard_faults;
	uint thread_high_watermark;
	ulong cycle_time;
	long create_time;
	long user_time;
	long kernel_time;
	UnicodeString image_name;
	int base_priority;
	ulong process_id;
	ulong parent_process_id;
	uint handle_count;
	uint session_id;
	ulong unique_process_key;
	usz peak_virtual_size;
	usz virtual_size;
	uint page_fault_count;
	usz peak_working_set_size;
	usz working_set_size;
}

<* MIB_IF_ROW2 (netioapi.h). The fields the service does not read keep their place in the layout. *>
struct MibIfRow2
{
	ulong interface_luid;
	uint interface_index;
	char[16] interface_guid;
	Char16[257] alias_name;
	Char16[257] description;
	uint physical_address_length;
	char[32] physical_address;
	char[32] permanent_physical_address;
	uint mtu;
	uint type;
	int tunnel_type;
	int media_type;
	int physical_medium_type;
	int access_type;
	int direction_type;
	char status_flags;
	int oper_status;
	int admin_status;
	int media_connect_state;
	char[16] network_guid;
	int connection_type;
	ulong transmit_link_speed;
	ulong receive_link_speed;
	ulong in_octets;
	ulong in_ucast_pkts;
	ulong in_nucast_pkts;
	ulong in_discards;
	ulong in_errors;
	ulong in_unknown_protos;
	ulong in_ucast_octets;
	ulong in_multicast_octets;
	ulong in_broadcast_octets;
	ulong out_octets;
	ulong out_ucast_pkts;
	ulong out_nucast_pkts;
	ulong out_discards;
	ulong out_errors;
	ulong out_ucast_octets;
	ulong out_multicast_octets;
	ulong out_broadcast_octets;
	ulong out_qlen;
}

<* RTL_OSVERSIONINFOW (winnt.h 6558). *>
struct OsVersionInfoW
{
	uint size;
	uint major;
	uint minor;
	uint build;
	uint platform_id;
	Char16[128] service_pack;
}

<* The leading field of TOKEN_USER: the SID pointer. *>
struct TokenUser
{
	void* sid;
	uint attributes;
}

extern fn int sys_nt_query_system_information(
	uint cls,
	void* buffer,
	uint length,
	uint* returned
) @cname("NtQuerySystemInformation");
extern fn int sys_rtl_get_version(OsVersionInfoW* info) @cname("RtlGetVersion");
extern fn int sys_call_nt_power_information(
	uint level,
	void* in_buffer,
	uint in_length,
	void* out_buffer,
	uint out_length
) @cname("CallNtPowerInformation");
extern fn ulong sys_get_tick_count_64() @cname("GetTickCount64");
extern fn int sys_get_computer_name(uint format, Char16* buffer, uint* size) @cname("GetComputerNameExW");
extern fn void sys_get_native_system_info(void* info) @cname("GetNativeSystemInfo");
extern fn int sys_global_memory_status_ex(MemoryStatusEx* status) @cname("GlobalMemoryStatusEx");
extern fn int sys_get_disk_free_space_ex(
	Char16* path,
	ulong* available,
	ulong* total,
	ulong* total_free
) @cname("GetDiskFreeSpaceExW");
extern fn void* sys_find_first_volume(Char16* name, uint length) @cname("FindFirstVolumeW");
extern fn int sys_find_next_volume(void* finder, Char16* name, uint length) @cname("FindNextVolumeW");
extern fn int sys_find_volume_close(void* finder) @cname("FindVolumeClose");
extern fn int sys_get_volume_path_names(
	Char16* volume,
	Char16* buffer,
	uint length,
	uint* returned
) @cname("GetVolumePathNamesForVolumeNameW");
extern fn uint sys_get_drive_type(Char16* path) @cname("GetDriveTypeW");
extern fn int sys_get_volume_information(
	Char16* root,
	Char16* volume_name,
	uint volume_name_size,
	uint* serial,
	uint* max_component,
	uint* flags,
	Char16* fs_name,
	uint fs_name_size
) @cname("GetVolumeInformationW");
extern fn uint sys_get_if_table_2(void** table) @cname("GetIfTable2");
extern fn void sys_free_mib_table(void* table) @cname("FreeMibTable");
extern fn void* sys_open_process(uint access, int inherit, uint process_id) @cname("OpenProcess");
extern fn int sys_open_process_token(void* process, uint access, void** token) @cname("OpenProcessToken");
extern fn int sys_get_token_information(
	void* token,
	uint cls,
	void* info,
	uint length,
	uint* returned
) @cname("GetTokenInformation");
extern fn int sys_lookup_account_sid(
	Char16* system,
	void* sid,
	Char16* name,
	uint* name_size,
	Char16* domain,
	uint* domain_size,
	uint* use
) @cname("LookupAccountSidW");