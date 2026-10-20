<*
 DMS wire shapes of the `bluetooth` module, written field by field in the Go order of
 DankMaterialShell's `core/internal/server/bluez/` at master 8be08999 (checked against
 the local checkout at that commit):

 * `BluetoothState` (types.go:10-16), `AdapterInfo` (types.go:19-25), `Device` (types.go:27-40);
 * `PairingPrompt` (types.go:58-67), the payload of the `bluetooth.pairing` stream, with the
   `requestType` and `fields` that `agent.go` (`RequestPinCode` ... `AuthorizeService`) sends;
 * `PoweredResult` (handlers.go:13-16).

 The values come from `bleu::bluetooth`. A field Bleu does not report is written empty
 or zero, and docs/DMSD.md lists each one.
*>
module dmsd::bluetooth_wire;
import std::collections::maybe, bleu::bluetooth, bleu::json, dmsd::wire;

// The `fields` of each prompt kind (agent.go: the `fields` argument of `promptFor`).
const String[1] PIN_FIELDS      = { "pin" };
const String[1] PASSKEY_FIELDS  = { "passkey" };
const String[1] DECISION_FIELDS = { "decision" };

<*
 The BlueZ icon name for a device icon, as `Device.Icon` carries it: the name
 `class_to_icon` (bluez src/dbus-common.c:53-115) gives the same class, or
 `gap_appearance_to_icon` (:117-146) the same appearance. The icon enum is coarser than
 BlueZ's own names, so the mapping is approximate: a watch or wearable has no BlueZ name,
 and "" is written for it (and for an unknown device).
*>
fn String icon_name(bluetooth::Icon icon)
{
	switch (icon)
	{
		case bluetooth::Icon.UNKNOWN: return "";
		case bluetooth::Icon.COMPUTER: return "computer";
		case bluetooth::Icon.PHONE: return "phone";
		case bluetooth::Icon.HEADSET: return "audio-headset";
		case bluetooth::Icon.HEADPHONES: return "audio-headphones";
		case bluetooth::Icon.LOUDSPEAKER: return "audio-card";
		case bluetooth::Icon.MICROPHONE: return "audio-card";
		case bluetooth::Icon.CAMERA: return "camera-video";
		case bluetooth::Icon.KEYBOARD: return "input-keyboard";
		case bluetooth::Icon.MOUSE: return "input-mouse";
		case bluetooth::Icon.JOYSTICK: return "input-gaming";
		case bluetooth::Icon.GAMEPAD: return "input-gaming";
		case bluetooth::Icon.PRINTER: return "printer";
		case bluetooth::Icon.DISPLAY: return "video-display";
		case bluetooth::Icon.WATCH: return "";
		case bluetooth::Icon.WEARABLE: return "";
	}
}

<*
 DMS's `alias` of a device: the user's alias when it differs from the device's own name.
 Bleu keeps only the display name (alias, else name, else address), so an alias equal to
 the name, which BlueZ reports as its own `Alias`, comes out empty here.
*>
fn String device_alias(bluetooth::Device* device)
{
	if (device.display_name == device.name || device.display_name == device.address) return "";
	return device.display_name;
}

// Whether an adapter's power is known to be on: an unknown state reads as off.
fn bool is_on(Maybe{bool} powered) => powered.has_value && powered.value;

// The name DMS shows for `address` (getDeviceInfo: alias, else name, else address), or the address when unknown.
fn String device_name(bluetooth::State* state, String address)
{
	foreach (&device : state.devices)
	{
		if (device.address == address) return device.display_name;
	}
	return address;
}

// One `Device` object (types.go:27-40). `path` is "" (Bleu's identity is the address), `legacyPairing` is false (not reported).
fn void? write_device(json::JsonWriter* w, bluetooth::Device* device)
{
	w.begin_object()!;
	wire::key_string(w, "path", "")!;
	wire::key_string(w, "address", device.address)!;
	wire::key_string(w, "name", device.name)!;
	wire::key_string(w, "alias", device_alias(device))!;
	wire::key_bool(w, "paired", device.paired)!;
	wire::key_bool(w, "trusted", device.trusted)!;
	wire::key_bool(w, "blocked", device.blocked)!;
	wire::key_bool(w, "connected", device.connected)!;
	wire::key_uint(w, "class", (ulong)device.class_of_device)!;
	wire::key_string(w, "icon", icon_name(device.icon))!;
	wire::key_int(w, "rssi", device.rssi.has_value ? (long)device.rssi.value : 0)!;
	wire::key_bool(w, "legacyPairing", false)!;
	w.end_object()!;
}

// One `AdapterInfo` object (types.go:19-25): `name` is the adapter's display name, as DMS's alias.
fn void? write_adapter(json::JsonWriter* w, bluetooth::Adapter* adapter)
{
	w.begin_object()!;
	wire::key_string(w, "path", "")!;
	wire::key_string(w, "name", adapter.display_name)!;
	wire::key_string(w, "address", adapter.address)!;
	wire::key_bool(w, "powered", is_on(adapter.powered))!;
	wire::key_bool(w, "discovering", adapter.discovering)!;
	w.end_object()!;
}

<*
 The `BluetoothState` of one snapshot (types.go:10-16). `powered` and `discovering` are those of the
 first controller, as DMS takes them (manager.go updateAdapterState); the first controller here is the
 one with the lowest address, where DMS's is the lowest object path.

 @return "The line, in `allocator`"
*>
fn String? render_state(Allocator allocator, bluetooth::State* state)
{
	bool powered     = false;
	bool discovering = false;
	if (state.adapters.len > 0)
	{
		powered     = is_on(state.adapters[0].powered);
		discovering = state.adapters[0].discovering;
	}
	wire::Line line;
	line.begin(allocator);
	json::JsonWriter* w = &line.writer;
	w.begin_object()!;
	wire::key_bool(w, "powered", powered)!;
	wire::key_bool(w, "discovering", discovering)!;
	w.key("adapters")!;
	w.begin_array()!;
	foreach (&adapter : state.adapters) write_adapter(w, adapter)!;
	w.end_array()!;
	w.key("devices")!;
	w.begin_array()!;
	foreach (&device : state.devices) write_device(w, device)!;
	w.end_array()!;
	w.key("pairedDevices")!;
	w.begin_array()!;
	foreach (&device : state.devices)
	{
		if (device.paired) write_device(w, device)!;
	}
	w.end_array()!;
	w.key("connectedDevices")!;
	w.begin_array()!;
	foreach (&device : state.devices)
	{
		if (device.connected) write_device(w, device)!;
	}
	w.end_array()!;
	w.end_object()!;
	return line.finish();
}

// The reply of `togglePowered` (handlers.go:13-16): `{"success":true,"powered":<bool>}`.
fn String? powered_result(Allocator allocator, bool powered)
{
	wire::Line line;
	line.begin(allocator);
	line.writer.begin_object()!;
	wire::key_bool(&line.writer, "success", true)!;
	wire::key_bool(&line.writer, "powered", powered)!;
	line.writer.end_object()!;
	return line.finish();
}

// The `requestType` of a prompt (agent.go). A displayed PIN is "display-pin"; a displayed passkey "display-passkey".
fn String request_type(bluetooth::Event* event) @private
{
	switch (event.request.kind)
	{
		case bluetooth::PromptKind.CONFIRM: return "confirm";
		case bluetooth::PromptKind.PIN: return "pin";
		case bluetooth::PromptKind.PASSKEY_DISPLAY: return event.text.len > 0 ? "display-pin" : "display-passkey";
		case bluetooth::PromptKind.PASSKEY_ENTRY: return "passkey";
		case bluetooth::PromptKind.AUTHORIZE: return "authorize";
	}
}

// The `fields` a prompt asks the shell to answer (agent.go). A display asks for nothing.
fn String[] prompt_fields(bluetooth::Event* event) @private
{
	String[] none;
	switch (event.request.kind)
	{
		case bluetooth::PromptKind.CONFIRM: return DECISION_FIELDS[..];
		case bluetooth::PromptKind.PIN: return PIN_FIELDS[..];
		case bluetooth::PromptKind.PASSKEY_DISPLAY: return none;
		case bluetooth::PromptKind.PASSKEY_ENTRY: return PASSKEY_FIELDS[..];
		case bluetooth::PromptKind.AUTHORIZE: return DECISION_FIELDS[..];
	}
}

// Whether DMS sends the passkey with a prompt: confirmations, and displayed passkeys (agent.go sets it for "confirm" and "display-passkey" only).
fn bool shows_passkey(bluetooth::Event* event) @private
{
	if (!event.request.passkey.has_value) return false;
	if (event.request.kind == bluetooth::PromptKind.CONFIRM) return true;
	return event.request.kind == bluetooth::PromptKind.PASSKEY_DISPLAY && event.text.len == 0;
}

// The `hints` text of a prompt: the code it shows (agent.go's `displayValue`), "" when there is none.
fn String hint_of(bluetooth::Event* event) @private
{
	if (event.request.kind == bluetooth::PromptKind.PASSKEY_DISPLAY && event.text.len > 0) return event.text;
	if (shows_passkey(event)) return string::tformat("%d", (long)event.request.passkey.value);
	return "";
}

<*
 One `PairingPrompt` (types.go:58-67) for `event`, which must be a PAIRING_REQUEST. `token` names the prompt in
 `bluetooth.pairing.submit`, and is "" for a code shown to the user, which needs no answer.

 @return "The line, in `allocator`"
*>
fn String? render_prompt(Allocator allocator, String token, bluetooth::Event* event, bluetooth::State* state)
{
	String address = event.request.device;
	String hint    = hint_of(event);
	String[1] hint_items = { hint };
	String[] none;
	String[] hints = none;
	if (hint.len > 0) hints = hint_items[..];
	wire::Line line;
	line.begin(allocator);
	json::JsonWriter* w = &line.writer;
	w.begin_object()!;
	wire::key_string(w, "token", token)!;
	wire::key_string(w, "devicePath", "")!;
	wire::key_string(w, "deviceName", device_name(state, address))!;
	wire::key_string(w, "deviceAddr", address)!;
	wire::key_string(w, "requestType", request_type(event))!;
	wire::key_strings(w, "fields", prompt_fields(event))!;
	wire::key_strings(w, "hints", hints)!;
	if (shows_passkey(event)) wire::key_uint(w, "passkey", (ulong)event.request.passkey.value)!;
	w.end_object()!;
	return line.finish();
}
