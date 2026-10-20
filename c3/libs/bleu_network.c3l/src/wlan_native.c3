<*
 The Native Wifi (WLAN) API that the Windows backend calls: its functions, its
 structures and the constants it uses. Compiled for Windows only.
 Nothing here has been run; see README.md for what is verified.

 Sources, each checked against the windows-sys 0.59.0 bindings
 (https://static.crates.io/crates/windows-sys/windows-sys-0.59.0.crate,
 src/Windows/Win32/NetworkManagement/WiFi/mod.rs) and the Microsoft Learn
 reference pages for the functions (wlanapi.h):
 * function signatures: mod.rs `windows_targets::link!("wlanapi.dll" ...)`;
 * structure layouts: WLAN_AVAILABLE_NETWORK (line 3912), WLAN_BSS_ENTRY (3967),
   WLAN_BSS_LIST (3987), WLAN_INTERFACE_INFO (4119), WLAN_INTERFACE_INFO_LIST (4126),
   WLAN_RATE_SET (4210), DOT11_SSID (3324), L2_NOTIFICATION_DATA (3803),
   WLAN_CONNECTION_PARAMETERS (4016);
 * constants: mod.rs lines 297-312 (DOT11_AUTH_ALGO_*), 978-980 (WLAN_AVAILABLE_NETWORK_*),
   999-1005 (WLAN_NOTIFICATION_SOURCE_*), 1194 (dot11_BSS_type_any), 1343-1350
   (wlan_interface_state_*), 1388-1407 (wlan_notification_acm_*).
 Win32 error codes (ERROR_NOT_FOUND 1168, ERROR_SERVICE_NOT_ACTIVE 1062) are the
 winerror.h values.
*>
module bleu::network::wlan_native @feat(WIN32) @link("wlanapi");
import bleu::win::guid;

<* WLAN_CLIENT_VERSION_LONGHORN: the client version of Windows Vista and later. *>
const uint CLIENT_VERSION = 2;

<* dwNotifSource: no notifications / the ACM (auto configuration module) notifications. *>
const uint NOTIFICATION_SOURCE_NONE = 0;
const uint NOTIFICATION_SOURCE_ACM  = 8;

<* WLAN_CONNECTION_MODE: connect with a named profile. *>
const int CONNECTION_MODE_PROFILE = 0;

<* DOT11_BSS_TYPE: any BSS type. *>
const int BSS_TYPE_ANY = 3;

<* WLAN_AVAILABLE_NETWORK flags. *>
const uint AVAILABLE_NETWORK_CONNECTED   = 1;
const uint AVAILABLE_NETWORK_HAS_PROFILE = 2;

<* WLAN_INTERFACE_STATE values. *>
const int INTERFACE_STATE_NOT_READY      = 0;
const int INTERFACE_STATE_AD_HOC_FORMED  = 2;
const int INTERFACE_STATE_DISCONNECTING  = 3;
const int INTERFACE_STATE_CONNECTED      = 1;
const int INTERFACE_STATE_DISCONNECTED   = 4;
const int INTERFACE_STATE_ASSOCIATING    = 5;
const int INTERFACE_STATE_DISCOVERING    = 6;
const int INTERFACE_STATE_AUTHENTICATING = 7;

<* WLAN_NOTIFICATION_ACM codes the backend acts on (it only refreshes on any of them). *>
const uint ACM_SCAN_COMPLETE = 7;
const uint ACM_CONNECTION_START = 9;
const uint ACM_CONNECTION_COMPLETE = 10;
const uint ACM_CONNECTION_ATTEMPT_FAIL = 11;
const uint ACM_DISCONNECTING = 20;
const uint ACM_DISCONNECTED = 21;

<* DOT11_AUTH_ALGORITHM values (mod.rs 297-312). *>
const int AUTH_OPEN = 1;
const int AUTH_SHARED_KEY = 2;
const int AUTH_WPA = 3;
const int AUTH_WPA_PSK = 4;
const int AUTH_RSNA = 6;
const int AUTH_RSNA_PSK = 7;
const int AUTH_WPA3 = 8;
const int AUTH_WPA3_SAE = 9;
const int AUTH_OWE = 10;
const int AUTH_WPA3_ENT = 11;

<* Win32 error codes. *>
const uint ERROR_NOT_FOUND = 1168;
const uint ERROR_SERVICE_NOT_ACTIVE = 1062;

<* DOT11_SSID: an SSID is up to 32 octets, and its length says how many are valid. *>
struct Dot11Ssid
{
	uint length;
	char[32] bytes;
}

<* WLAN_INTERFACE_INFO: one Wi-Fi interface. *>
struct WlanInterfaceInfo
{
	Guid guid;
	Char16[256] description;
	int state;
}

<* WLAN_INTERFACE_INFO_LIST: `items` is a variable-length array; index it with a pointer. *>
struct WlanInterfaceInfoList
{
	uint count;
	uint index;
	WlanInterfaceInfo[1] items;
}

<* WLAN_AVAILABLE_NETWORK: one network of the last scan, named by its profile and SSID. *>
struct WlanAvailableNetwork
{
	Char16[256] profile_name;
	Dot11Ssid ssid;
	int bss_type;
	uint bss_count;
	int connectable;
	uint not_connectable_reason;
	uint phy_count;
	int[8] phy_types;
	int more_phy_types;
	uint signal_quality;
	int security_enabled;
	int auth_algorithm;
	int cipher_algorithm;
	uint flags;
	uint reserved;
}

<* WLAN_AVAILABLE_NETWORK_LIST: `items` is a variable-length array. *>
struct WlanAvailableNetworkList
{
	uint count;
	uint index;
	WlanAvailableNetwork[1] items;
}

<* WLAN_RATE_SET. *>
struct WlanRateSet
{
	uint length;
	ushort[126] rates;
}

<* WLAN_BSS_ENTRY: one access point (BSSID) of a network. `rssi` is in dBm. *>
struct WlanBssEntry
{
	Dot11Ssid ssid;
	uint phy_id;
	char[6] bssid;
	int bss_type;
	int phy_type;
	int rssi;
	uint link_quality;
	char in_regulatory_domain;
	ushort beacon_period;
	ulong timestamp;
	ulong host_timestamp;
	ushort capability;
	uint center_frequency_khz;
	WlanRateSet rates;
	uint ie_offset;
	uint ie_size;
}

<* WLAN_BSS_LIST: `entries` is a variable-length array. *>
struct WlanBssList
{
	uint total_size;
	uint count;
	WlanBssEntry[1] entries;
}

<* WLAN_CONNECTION_PARAMETERS. *>
struct WlanConnectionParameters
{
	int mode;
	WString profile;
	Dot11Ssid* ssid;
	void* desired_bssids;
	int bss_type;
	uint flags;
}

<* L2_NOTIFICATION_DATA: what a notification callback is given. *>
struct L2NotificationData
{
	uint source;
	uint code;
	Guid interface_guid;
	uint data_size;
	void* data;
}

<* WLAN_NOTIFICATION_CALLBACK. Runs on a WLAN thread: it may only post to a mailbox. *>
alias NotificationCallback = fn void(L2NotificationData* data, void* context);

extern fn uint WlanOpenHandle(uint client_version, void* reserved, uint* negotiated_version, void** handle) @cname("WlanOpenHandle");
extern fn uint WlanCloseHandle(void* handle, void* reserved) @cname("WlanCloseHandle");
extern fn void WlanFreeMemory(void* memory) @cname("WlanFreeMemory");
extern fn uint WlanEnumInterfaces(void* handle, void* reserved, WlanInterfaceInfoList** list) @cname("WlanEnumInterfaces");
extern fn uint WlanGetAvailableNetworkList(void* handle, Guid* interface_guid, uint flags, void* reserved, WlanAvailableNetworkList** list) @cname("WlanGetAvailableNetworkList");
extern fn uint WlanGetNetworkBssList(void* handle, Guid* interface_guid, Dot11Ssid* ssid, int bss_type, int security_enabled, void* reserved, WlanBssList** list) @cname("WlanGetNetworkBssList");
extern fn uint WlanScan(void* handle, Guid* interface_guid, Dot11Ssid* ssid, void* ie_data, void* reserved) @cname("WlanScan");
extern fn uint WlanConnect(void* handle, Guid* interface_guid, WlanConnectionParameters* parameters, void* reserved) @cname("WlanConnect");
extern fn uint WlanDisconnect(void* handle, Guid* interface_guid, void* reserved) @cname("WlanDisconnect");
extern fn uint WlanSetProfile(void* handle, Guid* interface_guid, uint flags, WString profile_xml, WString all_user_security, int overwrite, void* reserved, uint* reason) @cname("WlanSetProfile");
extern fn uint WlanDeleteProfile(void* handle, Guid* interface_guid, WString profile_name, void* reserved) @cname("WlanDeleteProfile");
extern fn uint WlanRegisterNotification(void* handle, uint source, int ignore_duplicate, NotificationCallback callback, void* context, void* reserved, uint* previous_source) @cname("WlanRegisterNotification");
