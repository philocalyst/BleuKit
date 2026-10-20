<*
 Network state, as plain data.

 Wi-Fi networks are identified by their SSID, which is a sequence of raw bytes
 (IEEE 802.11 allows any 0..32 octets, not only UTF-8). `Ssid.label` is a
 convenience rendering for display and may be empty; compare and store the
 bytes. Values the platform cannot tell are `Maybe` empties, never zero.
*>
module bleu::network;
import std::collections::maybe, std::time, bleu::unit, bleu::operation;

<* IEEE 802.11 SSID length limit, in octets. *>
const usz SSID_MAX = 32;

<*
 Longest secret the service accepts. WPA2-PSK passphrases are 8 to 63
 characters; SAE passwords may be longer. The backend enforces the exact
 range of its own stack.
*>
const usz SECRET_MAX = 255;

<* A network name: its octets and a display rendering. *>
struct Ssid
{
	char[] bytes; // 0..32 octets, any values; this is the identity of the network
	String label; // UTF-8 rendering for display; "" when the bytes are not UTF-8 or are withheld
}

<* Radio band of a channel. *>
enum Band : char
{
	UNKNOWN,
	GHZ_2_4,
	GHZ_5,
	GHZ_6,
}

<* Security class of a network, as the strongest one it advertises. *>
enum Security : char
{
	OPEN,
	WEP,
	WPA_PSK,   // WPA1 pre-shared key
	WPA2_PSK,  // WPA2 pre-shared key (also what a WPA2/WPA3 transition network reports)
	WPA3_SAE,  // WPA3 personal (SAE only)
	OWE,       // Opportunistic Wireless Encryption: encrypted, no passphrase
	ENTERPRISE, // 802.1X; detected, not connectable in this version
	UNKNOWN,
}

<* Link state of a wired or wireless interface. *>
enum LinkState : char
{
	UNKNOWN,
	DOWN,
	UP,
	DORMANT,
}

<* Interfaces the service reports. *>
enum InterfaceKind : char
{
	WIFI,
	ETHERNET,
}

<* Internet reachability, as the OS judges it. *>
enum Connectivity : char
{
	UNKNOWN,
	NONE,
	PORTAL,  // a captive portal answers; the user must sign in through a browser
	LIMITED, // connected, but without internet access
	FULL,
}

<*
 Whether this process may see the names and addresses of nearby networks.
 macOS withholds SSIDs and BSSIDs from apps without Location authorization.
 Everywhere else the answer is NOT_APPLICABLE.
*>
enum LocationAccess : char
{
	NOT_APPLICABLE,
	UNKNOWN,
	NOT_DETERMINED,
	DENIED,
	RESTRICTED,
	AUTHORIZED,
}

<* Progress of the Wi-Fi connection, derived from the platform's own state machine. *>
enum ConnectionPhase : char
{
	IDLE,
	CONNECTING,
	AUTH_REQUIRED,    // the network needs a secret and none is available
	OBTAINING_ADDRESS,
	CONNECTED,
	DISCONNECTING,
	FAILED,           // `failure` says why
}

<*
 Why a connection failed. The NetworkManager device-state reasons are mapped
 by name (see `nm_convert.c3`); the other values are bleu's own classes.
*>
enum FailureReason : char
{
	NONE,
	UNKNOWN,
	NO_SECRETS,         // NM NO_SECRETS (7): a passphrase was needed and not supplied
	AUTH_REJECTED,      // a passphrase was supplied and the network asked for it again
	SUPPLICANT_FAILED,  // NM SUPPLICANT_DISCONNECT (8), SUPPLICANT_CONFIG_FAILED (9), SUPPLICANT_FAILED (10)
	SUPPLICANT_TIMEOUT, // NM SUPPLICANT_TIMEOUT (11)
	SSID_NOT_FOUND,     // NM SSID_NOT_FOUND (53)
	CONFIG_FAILED,      // NM CONFIG_FAILED (4)
	IP_CONFIG_FAILED,   // NM IP_CONFIG_UNAVAILABLE (5), IP_CONFIG_EXPIRED (6)
	DHCP_FAILED,        // NM DHCP_START_FAILED (15), DHCP_ERROR (16), DHCP_FAILED (17)
	CARRIER_LOST,       // NM CARRIER (40)
	DEVICE_UNAVAILABLE, // device removed, unmanaged, sleeping or its firmware missing
	DEPENDENCY_FAILED,  // NM DEPENDENCY_FAILED (50)
	NETWORKING_OFF,     // NM NETWORKING_OFF (78)
	CANCELLED,          // the user disconnected while connecting (NM USER_REQUESTED (39))
	TIMEOUT,            // bleu gave up waiting for the platform
}

<* One Wi-Fi network as the last scan saw it. Entries are unique per SSID. *>
struct AccessPoint
{
	Ssid ssid;
	String bssid;              // "" when unknown or withheld
	Maybe{MegaHertz} frequency;
	Maybe{Dbm} signal;         // dBm when the platform gives it
	Maybe{Level} quality;      // 0..1 when the platform gives a quality figure
	Band band;
	Security security;
	bool in_use;               // the connection the device is on
	bool known;                // a saved profile exists for this SSID
	bool autoconnect;          // meaningful only when `known`
}

<* Frequency in MHz. *>
typedef MegaHertz = uint;

<* Link speed in Mbit/s. *>
typedef Mbps = uint;

<* Traffic counter, in octets. *>
typedef Bytes = ulong;

<* One network interface the service manages. *>
struct Interface
{
	String name;
	InterfaceKind kind;
	LinkState link;
	Maybe{bool} carrier;       // the cable or radio link has carrier
	Maybe{Mbps} speed;
	Maybe{Bytes} rx_bytes;
	Maybe{Bytes} tx_bytes;
}

<* Wi-Fi radio and its connection. `present` is false when the machine has no Wi-Fi interface. *>
struct Wifi
{
	bool present;
	String interface_name;
	bool radio_enabled;        // software switch
	bool hardware_blocked;     // a physical switch or firmware refuses the radio
	bool scanning;
	bool ssid_visible;         // false when the OS withholds names from this process
	ConnectionPhase phase;
	FailureReason failure;     // NONE unless `phase` is FAILED or AUTH_REQUIRED
	Ssid connected_ssid;       // empty bytes when not connected or withheld
	Maybe{Dbm} signal;         // of the connected network
	AccessPoint[] networks;
}

<* The whole picture. Published as an immutable snapshot. *>
struct State
{
	Connectivity connectivity;
	LocationAccess location;
	String primary_interface;  // "" when there is no connection
	Wifi wifi;
	Interface[] interfaces;
}

<* Abilities of a backend. Every service operation has one. *>
enum Cap : char
{
	WIFI_RADIO,              // set_radio
	WIFI_SCAN,               // scan
	WIFI_CONNECT_OPEN,       // connect to an open network
	WIFI_CONNECT_PSK,        // connect with a passphrase given up front
	WIFI_DISCONNECT,         // disconnect
	WIFI_FORGET,             // forget a saved network
	WIFI_AUTOCONNECT,        // set_autoconnect
	WIFI_SECRET_PROMPT,      // CREDENTIALS_WANTED events, answered with supply_credentials
	SSID_VISIBILITY,         // SSID bytes are reported (false when withheld, see LocationAccess)
	WIFI_BSSID,              // BSSIDs are reported
	WIFI_SIGNAL_DBM,         // signal strength in dBm (otherwise only a quality figure)
	INTERFACE_STATE,         // link state and carrier per interface
	INTERFACE_SPEED,         // link speed per interface
	INTERFACE_COUNTERS,      // traffic counters per interface
	CONNECTIVITY,            // internet reachability
}

<* A transient: something happened. Re-read the state for the values. *>
enum EventKind : char
{
	NETWORKS_CHANGED,         // the list of visible networks changed
	CONNECTION_CHANGED,       // the phase or the connected network changed
	CREDENTIALS_WANTED,       // a passphrase is needed: answer with supply_credentials(request, secret)
	CREDENTIALS_WITHDRAWN,    // the request is no longer wanted: drop any prompt for it
	INTERFACES_CHANGED,       // an interface appeared, disappeared or changed link state
}

<* What kind of secret a request asks for. *>
enum SecretKind : char
{
	PASSPHRASE,
}

<* An event. Only the fields its kind names are meaningful. *>
struct Event
{
	EventKind kind;
	ulong request;        // CREDENTIALS_*: the id to answer with
	Ssid ssid;            // CREDENTIALS_*, CONNECTION_CHANGED: the network concerned
	SecretKind secret;    // CREDENTIALS_WANTED
}

<* Which mechanism provides the data. *>
enum Backend : char
{
	AUTO,
	NETWORKMANAGER, // Linux: org.freedesktop.NetworkManager over the system bus
	COREWLAN,       // macOS: CoreWLAN (public framework)
	WLAN_API,       // Windows: Native Wifi (wlanapi.dll) and IP Helper
}

<*
 How `open` finds and tunes a backend.
*>
struct Options
{
	Backend backend;   // AUTO tries every backend of the platform in priority order
	Duration poll;     // periodic re-read; 0 means the default (5 s)
	String root;       // prefix for sysfs; "" for the real system. Lets tests use a fake tree
	String bus_address; // D-Bus address for NetworkManager; "" for the system bus. Lets tests use a private bus
}

<* Completion value of a Wi-Fi connection: the network that is now in use. *>
struct Connected
{
	Ssid ssid;
	String interface_name;
}

<* Completion value of every other request: whether the world had to change. *>
enum Settled : char
{
	CHANGED,  // the request changed the state
	ALREADY,  // the state already was what was asked for
}

alias ConnectOp = Operation{Connected};
alias SettleOp = Operation{Settled};

<* Fixed-size copy of an SSID, so a command owns its bytes. *>
struct SsidBuffer
{
	char[SSID_MAX] bytes;
	usz len;
}

<* Fixed-size copy of a secret. Zeroed after use by the backend. *>
struct SecretBuffer
{
	char[SECRET_MAX] bytes;
	usz len;
}

enum CommandKind : char
{
	REFRESH,        // read the hardware now
	SCAN,
	CONNECT,
	DISCONNECT,
	FORGET,
	SET_RADIO,
	SET_AUTOCONNECT,
}

<*
 A request for the worker. Commands are in-process only: they are never
 published, serialised or compared. They carry the operation they complete
 (the worker releases the reference it was handed).
*>
struct Command
{
	CommandKind kind;
	bool flag;             // SET_RADIO, SET_AUTOCONNECT: the new value; CONNECT: autoconnect
	SsidBuffer ssid;       // CONNECT, FORGET, SET_AUTOCONNECT
	SecretBuffer secret;   // CONNECT: "" for open networks and saved profiles
	ConnectOp* connect;    // CONNECT
	SettleOp* settle;      // every other kind
}
