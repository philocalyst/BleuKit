<*
 The pairing agent: this process answers BlueZ's pairing requests, and turns
 each one into a `PAIRING_REQUEST` event that a user answers with
 `Bluetooth.reply_pairing`.

 BlueZ calls methods of org.bluez.Agent1 on the object the agent registers. The
 calls that need an answer are parked (`Call.defer_reply`), so the worker keeps
 running while the user decides, and `reply_pairing` answers them. The library
 never supplies a PIN, passkey or confirmation of its own: an empty PIN is
 refused, and nothing is accepted without the user's answer.

 The agent advertises the KeyboardDisplay capability, so BlueZ may ask for any
 of the prompts. Display-only requests (DisplayPinCode, DisplayPasskey) need no
 answer: they are reported as `PASSKEY_DISPLAY` requests with no waiting prompt.

 Sources: BlueZ org.bluez.Agent1 and AgentManager1 (docs/research/bluetooth.md
 section 2.1, [BZ-AGT] L24-146, [BZ-AGM] L171-232; capability table C6).
*>
module bleu::bluetooth::bluez @feat(LINUX);
import std::collections::maybe, bleu::bluetooth, bleu::dbus::marshal, bleu::dbus::message, bleu::dbus::proxy, bleu::dbus::server,
	bleu::dbus::value, bleu::error, bleu::observe, bleu::rt::worker;

<* Where the agent object lives on this process's connection. *>
const AGENT_PATH = "/org/bleu/bluetooth/agent";
<* BlueZ's AgentManager1 object, and the capability this agent advertises. *>
const AGENT_MANAGER_PATH = "/org/bluez";
const AGENT_MANAGER_IFACE = "org.bluez.AgentManager1";
const AGENT_IFACE = "org.bluez.Agent1";
const AGENT_CAPABILITY = "KeyboardDisplay";
<* The number of methods of org.bluez.Agent1. *>
const usz AGENT_METHOD_COUNT = 9;
<* Prompts that may wait for a user at once. A request beyond this is refused. *>
const usz MAX_PROMPTS = 8;
<* The longest PIN BlueZ accepts. *>
const usz PIN_MAX_LENGTH = 16;
<* The largest passkey: six decimal digits. *>
const uint PASSKEY_MAX = 999999;
<* The longest decimal passkey text. *>
const usz PASSKEY_DIGITS = 6;
<* Error names an agent returns when it refuses or cancels. *>
const String AGENT_REJECTED = "org.bluez.Error.Rejected";
const String AGENT_CANCELED = "org.bluez.Error.Canceled";

<* A request waiting for the user: its parked reply, its id, and the device it concerns. *>
struct Prompt
{
	bool waiting;
	ReplyToken token;
	ulong id;
	PromptKind kind;
	usz device_length;
	char[bluetooth::ADDRESS_TEXT_LENGTH] device;
}

<*
 Registers the agent: exports org.bluez.Agent1 on this connection, registers it
 with BlueZ and makes it the default. Runs on the worker thread.

 @return? error::BACKEND_FAILURE : "BlueZ refused the registration (the error is in error::last())"
*>
fn void? register_agent(Bluez* self) @private
{
	self.agent_methods = {
		{ .name = "Release", .in_signature = "", .out_signature = "", .handler = &on_release, .context = self },
		{ .name = "RequestPinCode", .in_signature = "o", .out_signature = "s", .handler = &on_request_pin, .context = self },
		{ .name = "DisplayPinCode", .in_signature = "os", .out_signature = "", .handler = &on_display_pin, .context = self },
		{ .name = "RequestPasskey", .in_signature = "o", .out_signature = "u", .handler = &on_request_passkey, .context = self },
		{ .name = "DisplayPasskey", .in_signature = "ouq", .out_signature = "", .handler = &on_display_passkey, .context = self },
		{ .name = "RequestConfirmation", .in_signature = "ou", .out_signature = "", .handler = &on_request_confirmation, .context = self },
		{ .name = "RequestAuthorization", .in_signature = "o", .out_signature = "", .handler = &on_request_authorization, .context = self },
		{ .name = "AuthorizeService", .in_signature = "os", .out_signature = "", .handler = &on_authorize_service, .context = self },
		{ .name = "Cancel", .in_signature = "", .out_signature = "", .handler = &on_cancel, .context = self },
	};
	self.agent_interfaces = { { .name = AGENT_IFACE, .methods = self.agent_methods[..] } };
	self.server.export(AGENT_PATH, self.agent_interfaces[..])!;
	@pool()
	{
		Proxy manager = proxy::for_object(&self.bus, BLUEZ_NAME, AGENT_MANAGER_PATH, AGENT_MANAGER_IFACE)!;
		Message* register = manager.new_call(tmem, "RegisterAgent")!;
		Writer* registered = register.body_writer("os")!;
		registered.append_object_path(AGENT_PATH)!;
		registered.append_string(AGENT_CAPABILITY)!;
		call_sync(self, register)!;
		Message* make_default = manager.new_call(tmem, "RequestDefaultAgent")!;
		make_default.body_writer("o")!.append_object_path(AGENT_PATH)!;
		call_sync(self, make_default)!;
	};
}

<* Unregisters the agent from BlueZ. The caller ignores a failure: the bus may be gone already. *>
fn void? unregister_agent(Bluez* self) @private
{
	@pool()
	{
		Proxy manager = proxy::for_object(&self.bus, BLUEZ_NAME, AGENT_MANAGER_PATH, AGENT_MANAGER_IFACE)!;
		Message* unregister = manager.new_call(tmem, "UnregisterAgent")!;
		unregister.body_writer("o")!.append_object_path(AGENT_PATH)!;
		call_sync(self, unregister)!;
	};
}

// BlueZ releases the agent: nothing waits for it any more.
fn void? on_release(void* context, Call* call) @private
{
	return call.reply(none_values());
}

// BlueZ asks for a PIN to type on the device. The user answers.
fn void? on_request_pin(void* context, Call* call) @private
{
	return park(context, call, PIN);
}

// BlueZ asks for a passkey to type on the device. The user answers.
fn void? on_request_passkey(void* context, Call* call) @private
{
	return park(context, call, PASSKEY_ENTRY);
}

// BlueZ asks the user to confirm a number shown on both devices.
fn void? on_request_confirmation(void* context, Call* call) @private
{
	return park(context, call, CONFIRM);
}

// BlueZ asks the user to allow a device to pair without a code.
fn void? on_request_authorization(void* context, Call* call) @private
{
	return park(context, call, AUTHORIZE);
}

// BlueZ asks the user to allow a service of a device.
fn void? on_authorize_service(void* context, Call* call) @private
{
	return park(context, call, AUTHORIZE);
}

// BlueZ shows a PIN the user must type on the device. The PIN is reported when it is numeric.
fn void? on_display_pin(void* context, Call* call) @private
{
	Bluez* self = (Bluez*)context;
	@pool()
	{
		Reader r = call.reader()!;
		String device = bluetooth::address_of_device_path(r.read_object_path()!, tmem) ?? "";
		String pin = r.read_string()!;
		uint passkey = parse_passkey(pin) ?? 0;
		Maybe{uint} shown = { };
		if (pin.len == PASSKEY_DIGITS) shown = maybe::value(passkey);
		report_display(self, device, shown);
	};
	return call.reply(none_values());
}

// BlueZ shows a passkey. It is reported once, when entry starts (`entered` is zero).
fn void? on_display_passkey(void* context, Call* call) @private
{
	Bluez* self = (Bluez*)context;
	@pool()
	{
		Reader r = call.reader()!;
		String device = bluetooth::address_of_device_path(r.read_object_path()!, tmem) ?? "";
		uint passkey = r.read_u32()!;
		ushort entered = r.read_u16()!;
		if (entered == 0) report_display(self, device, maybe::value(passkey));
	};
	return call.reply(none_values());
}

// BlueZ cancelled the requests it made: every waiting prompt is closed.
fn void? on_cancel(void* context, Call* call) @private
{
	Bluez* self = (Bluez*)context;
	foreach (&prompt : self.prompts)
	{
		if (!prompt.waiting) continue;
		close_prompt(self, prompt);
		// The reply is best effort: the bus may have dropped the parked call already.
		if (catch self.server.reply_error(prompt.token, AGENT_CANCELED, "pairing was cancelled")) {}
	}
	return call.reply(none_values());
}

// Parks a request that needs the user's answer, and tells the panel about it.
fn void? park(void* context, Call* call, PromptKind kind) @private
{
	Bluez* self = (Bluez*)context;
	Prompt* slot = free_slot(self) ?? null;
	if (slot == null) return call.reply_error(AGENT_REJECTED, "too many pairing prompts are waiting");
	String device = "";
	@pool()
	{
		Reader r = call.reader()!;
		device = bluetooth::address_of_device_path(r.read_object_path()!, tmem) ?? "";
	};
	slot.device_length = device.len;
	for (usz i = 0; i < bluetooth::ADDRESS_TEXT_LENGTH; i++) slot.device[i] = i < device.len ? device[i] : '\0';
	slot.token = call.defer_reply()!;
	slot.waiting = true;
	slot.id = ++self.next_prompt;
	slot.kind = kind;
	emit_request(self, kind, slot.id, device, { });
}

// An unused prompt slot, or NOT_FOUND when every slot is waiting.
fn Prompt*? free_slot(Bluez* self) @private
{
	foreach (&prompt : self.prompts)
	{
		if (!prompt.waiting) return prompt;
	}
	return NOT_FOUND~;
}

<*
 Answer a waiting prompt on the user's behalf. A refusal sends BlueZ a
 rejection. An acceptance sends what the kind needs: nothing, or a PIN, or a
 passkey. An invalid answer is refused and the prompt keeps waiting.

 @return? error::INVALID_STATE : "No prompt with this id is waiting"
 @return? error::INVALID_ARGUMENT : "The PIN or passkey is not valid"
*>
fn void? answer_prompt(Bluez* self, Request* r) @private
{
	Prompt* prompt = find_prompt(self, r.ticket) ?? null;
	if (prompt == null) return error::INVALID_STATE~;
	if (!r.flag)
	{
		self.server.reply_error(prompt.token, AGENT_REJECTED, "rejected by the user")!;
		return close_prompt(self, prompt);
	}
	switch (prompt.kind)
	{
		case CONFIRM:
		case AUTHORIZE:
			self.server.reply(prompt.token, none_values())!;
		case PIN:
			if (r.text.len == 0 || r.text.len > PIN_MAX_LENGTH) return error::INVALID_ARGUMENT~;
			Value[1] pin = { value::str(tmem, r.text)! };
			self.server.reply(prompt.token, pin[..])!;
		case PASSKEY_ENTRY:
			uint passkey = parse_passkey(r.text)!;
			Value[1] values = { value::u32(passkey) };
			self.server.reply(prompt.token, values[..])!;
		case PASSKEY_DISPLAY:
			return error::INVALID_STATE~;
	}
	return close_prompt(self, prompt);
}

// The waiting prompt with `id`, or NOT_FOUND.
fn Prompt*? find_prompt(Bluez* self, ulong id) @private
{
	foreach (&prompt : self.prompts)
	{
		if (prompt.waiting && prompt.id == id) return prompt;
	}
	return NOT_FOUND~;
}

// Marks a prompt answered and tells the panel that it no longer waits.
fn void close_prompt(Bluez* self, Prompt* prompt) @private
{
	prompt.waiting = false;
	emit_ended(self, prompt.id);
}

<* A passkey as decimal digits: at most six, and no greater than PASSKEY_MAX. *>
fn uint? parse_passkey(String text) @private
{
	if (text.len == 0 || text.len > PASSKEY_DIGITS) return error::INVALID_ARGUMENT~;
	uint value = 0;
	foreach (c : text)
	{
		if (c < '0' || c > '9') return error::INVALID_ARGUMENT~;
		value = value * 10 + (uint)(c - '0');
	}
	if (value > PASSKEY_MAX) return error::INVALID_ARGUMENT~;
	return value;
}

fn Value[] none_values() @private
{
	Value[] none;
	return none;
}

// A request that waits for the user. `device` is copied into the event.
fn void emit_request(Bluez* self, PromptKind kind, ulong id, String device, Maybe{uint} passkey) @private
{
	Snapshot{Event}* packet = self.hub.emit_begin();
	Allocator arena = packet.allocator();
	String address = bluetooth::copy_text(device, arena);
	packet.value = {
		.kind = EventKind.PAIRING_REQUEST,
		.address = address,
		.request = { .id = id, .device = address, .kind = kind, .passkey = passkey },
	};
	self.hub.emit(packet);
}

// A passkey shown to the user: a request with nothing to answer.
fn void report_display(Bluez* self, String device, Maybe{uint} passkey) @private
{
	emit_request(self, PASSKEY_DISPLAY, 0, device, passkey);
}

// The end of a waiting prompt.
fn void emit_ended(Bluez* self, ulong id) @private
{
	Snapshot{Event}* packet = self.hub.emit_begin();
	packet.value = { .kind = EventKind.PAIRING_ENDED, .request = { .id = id } };
	self.hub.emit(packet);
}
