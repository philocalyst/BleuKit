<*
 NetworkManager's numbers, turned into Bleu's types. Pure: no I/O, no bus.

 Every constant is cited to two sources: the NetworkManager D-Bus API
 reference (https://networkmanager.dev/docs/api/latest/nm-dbus-types.html)
 and the nmrs 3.5.6 crate, which mirrors it (src/api/models/state_reason.rs,
 src/api/models/device.rs; https://static.crates.io/crates/nmrs/nmrs-3.5.6.crate).
 See docs/research/network.md section 2.1.1 for the full tables.
*>
module bleu::network::nm_convert;
import std::collections::maybe, bleu::unit, bleu::network;

<* NM_DEVICE_TYPE_ETHERNET (nm-dbus-types). *>
const uint DEVICE_TYPE_ETHERNET = 1;
<* NM_DEVICE_TYPE_WIFI (nm-dbus-types). *>
const uint DEVICE_TYPE_WIFI     = 2;

<* NMDeviceState values (nm-dbus-types). *>
const uint DEVICE_STATE_UNMANAGED    = 10;
const uint DEVICE_STATE_UNAVAILABLE  = 20;
const uint DEVICE_STATE_DISCONNECTED = 30;
const uint DEVICE_STATE_PREPARE      = 40;
const uint DEVICE_STATE_CONFIG       = 50;
const uint DEVICE_STATE_NEED_AUTH    = 60;
const uint DEVICE_STATE_IP_CONFIG    = 70;
const uint DEVICE_STATE_IP_CHECK     = 80;
const uint DEVICE_STATE_SECONDARIES  = 90;
const uint DEVICE_STATE_ACTIVATED    = 100;
const uint DEVICE_STATE_DEACTIVATING = 110;
const uint DEVICE_STATE_FAILED       = 120;

<* NMDeviceStateReason values used by the mapping (nm-dbus-types; nmrs state_reason.rs). *>
const uint REASON_NONE                     = 0;
const uint REASON_CONFIG_FAILED            = 4;
const uint REASON_IP_CONFIG_UNAVAILABLE    = 5;
const uint REASON_IP_CONFIG_EXPIRED        = 6;
const uint REASON_NO_SECRETS               = 7;
const uint REASON_SUPPLICANT_DISCONNECT    = 8;
const uint REASON_SUPPLICANT_CONFIG_FAILED = 9;
const uint REASON_SUPPLICANT_FAILED        = 10;
const uint REASON_SUPPLICANT_TIMEOUT       = 11;
const uint REASON_DHCP_START_FAILED        = 15;
const uint REASON_DHCP_ERROR               = 16;
const uint REASON_DHCP_FAILED              = 17;
const uint REASON_DEVICE_REMOVED           = 36;
const uint REASON_SLEEPING                 = 37;
const uint REASON_CONNECTION_REMOVED       = 38;
const uint REASON_USER_REQUESTED           = 39;
const uint REASON_CARRIER                  = 40;
const uint REASON_DEPENDENCY_FAILED        = 50;
const uint REASON_SSID_NOT_FOUND           = 53;
const uint REASON_FIRMWARE_MISSING         = 35;
const uint REASON_NETWORKING_OFF           = 78;

<* NM80211ApFlags and NM80211ApSecurityFlags (nm-dbus-types; nmrs access_point.rs). *>
const uint AP_FLAGS_PRIVACY       = 0x00000001;
const uint AP_SEC_KEY_MGMT_PSK    = 0x00000100;
const uint AP_SEC_KEY_MGMT_802_1X = 0x00000200;
const uint AP_SEC_KEY_MGMT_SAE    = 0x00000400;
const uint AP_SEC_KEY_MGMT_OWE    = 0x00000800;

<* Wi-Fi band frequency ranges in MHz, from the IEEE 802.11 channel plans (2.4 GHz, 5 GHz, 6 GHz). *>
const uint BAND_2_4_MIN = 2400;
const uint BAND_2_4_MAX = 2500;
const uint BAND_5_MIN   = 4900;
const uint BAND_5_MAX   = 5900;
const uint BAND_6_MIN   = 5925;
const uint BAND_6_MAX   = 7125;

<* Band of a frequency in MHz. *>
fn Band band_from_mhz(uint mhz)
{
	if (mhz >= BAND_2_4_MIN && mhz <= BAND_2_4_MAX) return GHZ_2_4;
	if (mhz >= BAND_6_MIN && mhz <= BAND_6_MAX) return GHZ_6;
	if (mhz >= BAND_5_MIN && mhz <= BAND_5_MAX) return GHZ_5;
	return UNKNOWN;
}

<*
 Security class from NM's access-point flags. `flags` is the AP's `Flags`,
 `wpa` its `WpaFlags` (WPA1 key management), `rsn` its `RsnFlags` (WPA2/WPA3).
 A WPA2/WPA3 transition network (both PSK and SAE) is reported as WPA2_PSK,
 because every client can join it with a passphrase.
*>
fn Security security_from_flags(uint flags, uint wpa, uint rsn)
{
	if (((rsn | wpa) & AP_SEC_KEY_MGMT_802_1X) != 0) return ENTERPRISE;
	if ((rsn & AP_SEC_KEY_MGMT_OWE) != 0) return OWE;
	if ((rsn & AP_SEC_KEY_MGMT_PSK) != 0) return WPA2_PSK;
	if ((rsn & AP_SEC_KEY_MGMT_SAE) != 0) return WPA3_SAE;
	if ((wpa & AP_SEC_KEY_MGMT_PSK) != 0) return WPA_PSK;
	// No WPA element at all: static WEP sets the privacy bit, an open network does not.
	// WPS bits in `flags` say nothing about the key management.
	if (wpa == 0 && rsn == 0) return (flags & AP_FLAGS_PRIVACY) != 0 ? WEP : OPEN;
	return UNKNOWN;
}

<*
 Failure class for an NM device state reason. Reasons with no Bleu class
 are UNKNOWN; the number is kept in the error detail by the caller.
*>
fn FailureReason failure_from_reason(uint reason)
{
	switch (reason)
	{
		case REASON_NONE: return NONE;
		case REASON_CONFIG_FAILED: return CONFIG_FAILED;
		case REASON_IP_CONFIG_UNAVAILABLE:
		case REASON_IP_CONFIG_EXPIRED: return IP_CONFIG_FAILED;
		case REASON_NO_SECRETS: return NO_SECRETS;
		case REASON_SUPPLICANT_DISCONNECT:
		case REASON_SUPPLICANT_CONFIG_FAILED:
		case REASON_SUPPLICANT_FAILED: return SUPPLICANT_FAILED;
		case REASON_SUPPLICANT_TIMEOUT: return SUPPLICANT_TIMEOUT;
		case REASON_DHCP_START_FAILED:
		case REASON_DHCP_ERROR:
		case REASON_DHCP_FAILED: return DHCP_FAILED;
		case REASON_CARRIER: return CARRIER_LOST;
		case REASON_SSID_NOT_FOUND: return SSID_NOT_FOUND;
		case REASON_DEVICE_REMOVED:
		case REASON_SLEEPING:
		case REASON_CONNECTION_REMOVED:
		case REASON_FIRMWARE_MISSING: return DEVICE_UNAVAILABLE;
		case REASON_DEPENDENCY_FAILED: return DEPENDENCY_FAILED;
		case REASON_NETWORKING_OFF: return NETWORKING_OFF;
		case REASON_USER_REQUESTED: return CANCELLED;
		default: return UNKNOWN;
	}
}

<*
 Connection phase for an NM device state. NEED_AUTH is reported as
 AUTH_REQUIRED here; the caller turns it into AUTH_REJECTED when it had already
 supplied a passphrase.
*>
fn ConnectionPhase phase_from_device_state(uint state)
{
	switch (state)
	{
		case DEVICE_STATE_PREPARE:
		case DEVICE_STATE_CONFIG: return CONNECTING;
		case DEVICE_STATE_NEED_AUTH: return AUTH_REQUIRED;
		case DEVICE_STATE_IP_CONFIG:
		case DEVICE_STATE_IP_CHECK:
		case DEVICE_STATE_SECONDARIES: return OBTAINING_ADDRESS;
		case DEVICE_STATE_ACTIVATED: return CONNECTED;
		case DEVICE_STATE_DEACTIVATING: return DISCONNECTING;
		case DEVICE_STATE_FAILED: return FAILED;
		default: return IDLE;
	}
}

<*
 Whether a device state is one the device passes through while activating
 (PREPARE to SECONDARIES). Terminal states are the other kinds.
*>
fn bool is_activation_state(uint state)
{
	switch (state)
	{
		case DEVICE_STATE_PREPARE:
		case DEVICE_STATE_CONFIG:
		case DEVICE_STATE_NEED_AUTH:
		case DEVICE_STATE_IP_CONFIG:
		case DEVICE_STATE_IP_CHECK:
		case DEVICE_STATE_SECONDARIES: return true;
		default: return false;
	}
}

<* NMConnectivityState (nm-dbus-types). *>
fn Connectivity connectivity_from(uint nm_value)
{
	switch (nm_value)
	{
		case 1: return NONE;
		case 2: return PORTAL;
		case 3: return LIMITED;
		case 4: return FULL;
		default: return UNKNOWN;
	}
}

<* The interface kind of an NM device type, or NOT_FOUND for types the service does not report. *>
fn InterfaceKind? kind_from_device_type(uint device_type)
{
	switch (device_type)
	{
		case DEVICE_TYPE_WIFI: return WIFI;
		case DEVICE_TYPE_ETHERNET: return ETHERNET;
		default: return NOT_FOUND~;
	}
}

<*
 A NetworkManager strength (0..100, the AP's `Strength`) as a quality level.
 NM gives no dBm, so Wi-Fi signal in dBm stays empty on this backend.
*>
fn Level quality_from_strength(uint strength) => unit::from_percent((float)strength);