<*
 Bluetooth adapters, devices, pairing prompts and the operations on them, as
 plain data.

 Everything a panel shows: which controllers exist and whether they are on,
 which devices are known and how they relate to this computer (paired, trusted,
 connected), and the pairing prompts that a user must answer. Values the
 platform cannot tell are `Maybe` empties, never zero: a device with no
 battery report is not a device at 0 %.

 Addresses are the Bluetooth device address as text, "AA:BB:CC:DD:EE:FF" in
 upper case, and are the identity of an adapter or device across snapshots.
*>
module bleu::bluetooth;
import std::collections::maybe, bleu::unit;

<* One controller (an adapter, in BlueZ terms). *>
struct Adapter
{
	String address; // the controller's Bluetooth address; its identity
	String name; // the controller's own name, "" when unknown
	String display_name; // what to show: the user's alias, else the name
	bool powered; // the radio is on
	bool blocked; // a kill switch or firmware block holds the radio off; it cannot be powered on
	bool discoverable; // other devices can find it right now
	uint discoverable_timeout_s; // seconds until discoverable turns off again; 0 means until switched off
	bool pairable; // other devices may pair with it
	bool discovering; // a scan for nearby devices is running
}

<* How a device relates to this computer, derived from its class and appearance. *>
enum Icon : char
{
	UNKNOWN,
	COMPUTER,
	PHONE,
	HEADSET,
	HEADPHONES,
	LOUDSPEAKER,
	MICROPHONE,
	CAMERA,
	KEYBOARD,
	MOUSE,
	JOYSTICK,
	GAMEPAD,
	PRINTER,
	DISPLAY,
	WATCH,
	WEARABLE,
}

<* A profile this library knows by name. Each one has a Bluetooth service UUID. *>
enum Profile : char
{
	A2DP_SOURCE, // audio source: this computer sends audio
	A2DP_SINK, // audio sink: this computer plays audio
	HSP_HEADSET, // headset profile, headset role
	HSP_GATEWAY, // headset profile, audio gateway role
	HFP_HANDSFREE, // hands-free profile, hands-free role
	HFP_GATEWAY, // hands-free profile, audio gateway role
}

<* Which PnP id source a modalias names. *>
enum PnpSource : char
{
	BLUETOOTH, // the vendor id is a Bluetooth SIG company id
	USB, // the vendor id is a USB-IF id
	OTHER,
}

<* The vendor and product of a device, from its modalias. *>
struct PnpId
{
	PnpSource source;
	ushort vendor;
	ushort product;
	ushort version;
}

<* One remote device, as this computer knows it. *>
struct Device
{
	String address; // the device's Bluetooth address; its identity
	String adapter; // address of the controller that knows it
	String name; // the device's own name, "" when none was read
	String display_name; // what to show: alias, else name, else the address
	Icon icon;
	uint class_of_device; // 24-bit class of device; 0 when unknown
	ushort appearance; // BLE appearance; 0 when unknown
	bool paired; // keys are stored for it
	bool bonded; // paired and the keys are permanent
	bool connected; // the link is up
	bool trusted; // it may connect without asking
	bool blocked; // its connections are refused
	bool services_resolved; // its service list has been read
	Maybe{Dbm} rssi; // signal strength, only while it is being seen
	Maybe{Level} battery; // charge of the device's own battery
	Maybe{PnpId} pnp; // vendor and product, when it reports a modalias
	String modalias; // raw modalias text, "" when none
	String[] uuids; // service class UUIDs, lower case
	Profile[] profiles; // those of the UUIDs that are known profiles
}

<*
 The whole picture: every controller and every device known to the backend.
*>
struct State
{
	Adapter[] adapters;
	Device[] devices;
}

<* Which optional operation. `Bluetooth.capability` says whether it works here. *>
enum Cap : char
{
	POWER, // switch a controller on and off
	DISCOVERABLE, // make a controller visible to others, with a timeout
	PAIRABLE, // accept pairing requests on a controller
	DISCOVERY, // scan for nearby devices, with a filter
	PAIR, // pair with a device
	CANCEL_PAIRING, // stop a pairing that is in progress
	PAIRING_PROMPTS, // receive pairing prompts as events and answer them
	CONNECT, // connect a whole device
	DISCONNECT, // disconnect a whole device
	PROFILE_CONNECT, // connect one profile of a device
	PROFILE_DISCONNECT, // disconnect one profile of a device
	TRUST, // set whether a device may connect without asking
	BLOCK, // set whether a device's connections are refused
	RENAME, // change a device's alias
	REMOVE, // forget a device
	BATTERY, // read a device's battery level
	RSSI, // read a device's signal strength
	SERVICE_UUIDS, // read a device's service UUIDs
	MODALIAS, // read a device's vendor and product
	RFKILL_STATE, // report a radio held off by a kill switch
}

<*
 Kinds of pairing prompt. The answer comes back through
 `Bluetooth.reply_pairing`; a PIN is never answered by the library itself.
*>
enum PromptKind : char
{
	CONFIRM, // show the number; the user says whether it matches
	PIN, // the user types a PIN for the device
	PASSKEY_DISPLAY, // show the passkey; the user types it on the device
	PASSKEY_ENTRY, // the user types the passkey shown on the device
	AUTHORIZE, // the user says whether this device may pair without a code
}

<*
 A pairing prompt. `id` names it in `reply_pairing` and in the matching
 `PAIRING_ENDED` event. `passkey` is set for CONFIRM and PASSKEY_DISPLAY.
*>
struct PairingRequest
{
	ulong id;
	String device;
	PromptKind kind;
	Maybe{uint} passkey;
}

<* Which link a discovery scan uses. *>
enum Transport : char
{
	AUTO, // whatever the controller prefers
	LE, // Bluetooth Low Energy only
	BR_EDR, // classic Bluetooth only
}

<*
 Filter for a discovery scan. `duplicates` reports a device again on every
 advertisement, which is how signal strength keeps updating.
*>
struct DiscoveryFilter
{
	Transport transport;
	bool duplicates;
	Maybe{Dbm} rssi_floor; // ignore devices seen weaker than this
	String pattern; // only devices whose name starts with this, "" for all
}

<* Which mechanism provides the data. *>
enum Backend : char
{
	AUTO, // every backend of the platform, best first
	BLUEZ, // Linux: org.bluez on the D-Bus system bus
	IOBLUETOOTH, // macOS: IOBluetooth (public calls, plus private calls when enabled)
	WIN32, // Windows: the Bluetooth Win32 functions, loaded at run time
}

<*
 How `open` finds and tunes a backend.

 `bus_address` is a D-Bus address of the bus that carries org.bluez; "" means
 the system bus. `root` is a prefix for kernel pseudo-files (rfkill), "" for the
 real system; tests use it to substitute a fake tree. `private_api` allows the
 undocumented IOBluetooth calls (power, discoverability, unpair) on macOS; it is
 off by default because those calls are not part of any public API.
*>
struct Options
{
	Backend backend;
	String bus_address;
	String root;
	bool private_api;
}

<* What happened, for subscribers. Re-read `latest()` for the values. *>
enum EventKind : char
{
	ADAPTER_ADDED,
	ADAPTER_REMOVED,
	ADAPTER_CHANGED,
	DEVICE_ADDED,
	DEVICE_REMOVED,
	DEVICE_CHANGED,
	DEVICE_DISCONNECTED, // `text` is the reason the bus or the controller gave
	PAIRING_REQUEST, // `request` holds the prompt
	PAIRING_ENDED, // `request.id` names the prompt that is no longer waiting for an answer
}

<* A transient. `address` is the controller or device concerned, "" when none. *>
struct Event
{
	EventKind kind;
	String address;
	String text;
	PairingRequest request;
}

<*
 The operations a caller can ask for. Each one is an `Operation` returned by
 the matching `Bluetooth` method; the list is internal to the worker.
*>
enum Command : char
{
	SET_POWERED,
	SET_DISCOVERABLE,
	SET_PAIRABLE,
	START_DISCOVERY,
	STOP_DISCOVERY,
	PAIR,
	CANCEL_PAIRING,
	CONNECT,
	DISCONNECT,
	CONNECT_PROFILE,
	DISCONNECT_PROFILE,
	SET_TRUSTED,
	SET_BLOCKED,
	RENAME,
	REMOVE,
	REPLY_PAIRING,
	REFRESH,
}

<*
 The value of an operation that has no result beyond success. Failures are
 reported through the operation's fault.
*>
enum Done : char
{
	DONE,
}
