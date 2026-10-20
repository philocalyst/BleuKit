// The NetworkManager secret agent: this process answers NetworkManager's requests
// for a Wi-Fi passphrase. NetworkManager calls GetSecrets on the object it
// expects (/org/freedesktop/NetworkManager/SecretAgent) on the connection that
// registered the agent. Each call is parked as a prompt with a deferred reply:
// the service publishes CREDENTIALS_WANTED, and the answer (supply_credentials)
// or the refusal (cancel_credentials) completes the reply.
// 
// Interface and error names: org.freedesktop.NetworkManager.SecretAgent (the
// introspection XML SecretAgent.xml in the NetworkManager repository, cited in
// docs/research/network.md section 2.1.1; the methods and the flag value 0x1 are
// the same in nmrs 3.5.6, src/agent/iface.rs and src/agent/request.rs).
// NM_SECRET_AGENT_GET_SECRETS_FLAG_ALLOW_INTERACTION is 0x1 (nm-dbus-types).
module bleu::network::networkmanager @feat(LINUX);
import std::collections::list, bleu::error, bleu::network, bleu::network::nm_settings, bleu::dbus::connection, bleu::dbus::marshal, bleu::dbus::proxy, bleu::dbus::server, bleu::dbus::value;

const String AGENT_PATH                  = "/org/freedesktop/NetworkManager/SecretAgent";
const String AGENT_IFACE                 = "org.freedesktop.NetworkManager.SecretAgent";
const String AGENT_IDENTIFIER            = "org.bleu.network";
const String AGENT_MANAGER_PATH          = "/org/freedesktop/NetworkManager/AgentManager";
const String AGENT_MANAGER_IFACE         = "org.freedesktop.NetworkManager.AgentManager";
const String ERROR_NO_SECRETS            = "org.freedesktop.NetworkManager.SecretAgent.Error.NoSecrets";
const String ERROR_USER_CANCELED         = "org.freedesktop.NetworkManager.SecretAgent.Error.UserCanceled";
const String SECURITY_SETTING            = "802-11-wireless-security";
const uint SECRET_FLAG_ALLOW_INTERACTION = 0x1;

<* A GetSecrets call waiting for the user. The strings and octets are in the backend's allocator. *>
struct Prompt
{
	ulong id;
	String connection_path;
	String setting;
	char[] ssid;
	ReplyToken token;
}

<* The agent's interface, as the backend exports it. The methods' contexts are the backend. *>
fn server::Interface agent_interface(Backend* b, server::Method[] methods)
{
	methods[0] = {
		.name = "GetSecrets",
		.in_signature = "a{sa{sv}}osasu",
		.out_signature = "a{sa{sv}}",
		.handler = &on_get_secrets,
		.context = b
	};
	methods[1] = {
		.name = "CancelGetSecrets",
		.in_signature = "os",
		.out_signature = "",
		.handler = &on_cancel_get_secrets,
		.context = b
	};
	methods[2] = {
		.name = "SaveSecrets",
		.in_signature = "a{sa{sv}}o",
		.out_signature = "",
		.handler = &on_save_secrets,
		.context = b
	};
	methods[3] = {
		.name = "DeleteSecrets",
		.in_signature = "a{sa{sv}}o",
		.out_signature = "",
		.handler = &on_delete_secrets,
		.context = b
	};
	return { .name = AGENT_IFACE, .methods = methods[..] };
}

<*
 NetworkManager asks for the secrets of a connection. Only the Wi-Fi passphrase
 is supplied, and only when the request allows interaction; otherwise it is refused
 with NoSecrets. An allowed request is parked until the user answers.
*>
fn void? on_get_secrets(void* context, Call* call)
{
	Backend* b       = (Backend*)context;
	Reader r         = call.reader()!;
	Value connection = r.read_value(tmem)!;
	String path      = r.read_object_path()!;
	String setting   = r.read_string()!;
	r.read_value(tmem)!;
	uint flags = r.read_u32()!;
	if (setting != SECURITY_SETTING) return call.reply_error(ERROR_NO_SECRETS, "only the Wi-Fi passphrase is supplied");
	if ((flags & SECRET_FLAG_ALLOW_INTERACTION) == 0) return call.reply_error(
		ERROR_NO_SECRETS,
		"the request does not allow interaction"
	);
	Value wireless = connection.dict_get(nm_settings::GROUP_WIRELESS)!;
	char[] ssid    = bytes_of(tmem, wireless, "ssid");
	if (ssid.len == 0) return call.reply_error(ERROR_NO_SECRETS, "the connection has no network name");
	ReplyToken token = call.defer_reply()!;
	// NetworkManager asks again when the passphrase it got was refused: the older prompt is superseded.
	withdraw(b, path, setting, ERROR_USER_CANCELED, "superseded by a newer request");
	b.prompt_sequence++;
	Allocator allocator = b.allocator;
	b.prompts.push(
		{
			.id = b.prompt_sequence,
			.connection_path = path.copy(allocator),
			.setting = setting.copy(allocator),
			.ssid = alloc::clone_slice(allocator, ssid),
			.token = token,
		}
	);
	network::emit_event(
		b.hub,
		{ .kind = CREDENTIALS_WANTED, .request = b.prompt_sequence, .ssid = { .bytes = ssid }, .secret = PASSPHRASE }
	);
}

<* NetworkManager no longer needs the answer to a prompt: the call is refused and the prompt dropped. *>
fn void? on_cancel_get_secrets(void* context, Call* call)
{
	Backend* b     = (Backend*)context;
	Reader r       = call.reader()!;
	String path    = r.read_object_path()!;
	String setting = r.read_string()!;
	withdraw(b, path, setting, ERROR_USER_CANCELED, "the request was withdrawn");
	Value[] none = { };
	return call.reply(none);
}

// NetworkManager keeps the secrets itself, so the agent has nothing to store or forget.
fn void? on_save_secrets(void* context, Call* call)
{
	Value[] none = { };
	return call.reply(none);
}

fn void? on_delete_secrets(void* context, Call* call)
{
	Value[] none = { };
	return call.reply(none);
}

// Index of the prompt with this id.
fn sz? find_prompt(Backend* b, ulong id)
{
	foreach (i, prompt : b.prompts.array_view())
	{
		if (prompt.id == id) return i;
	}
	return NOT_FOUND~;
}

// Refuse and drop every prompt for this connection and setting.
fn void withdraw(Backend* b, String path, String setting, String error_name, String text) @local
{
	sz i = 0;
	while (i < b.prompts.len())
	{
		Prompt* prompt = b.prompts.get_ref(i);
		if (prompt.connection_path != path || prompt.setting != setting)
		{
			i++;
			continue;
		}
		if (catch err = b.server.reply_error(prompt.token, error_name, text))
		{
		} // the caller is gone; nothing to answer
		drop_prompt(b, i);
	}
}

// Refuse and drop the prompt at `index`.
fn void drop_prompt(Backend* b, sz index)
{
	Prompt* prompt      = b.prompts.get_ref(index);
	Allocator allocator = b.allocator;
	drop_text(allocator, prompt.connection_path);
	drop_text(allocator, prompt.setting);
	if (prompt.ssid.len > 0) alloc::free(allocator, prompt.ssid.ptr);
	b.prompts.remove_at(index);
}

// Refuse every prompt still waiting. Used when the service stops.
fn void abandon_prompts(Backend* b)
{
	while (b.prompts.len() > 0)
	{
		Prompt* prompt = b.prompts.get_ref(0);
		if (catch err = b.server.reply_error(prompt.token, ERROR_USER_CANCELED, "the service stopped"))
		{
		}
		drop_prompt(b, 0);
	}
}

// Register the agent with NetworkManager. The object is already exported.
fn void? register_agent(Backend* b)
{
	Proxy manager = object_proxy(&b.bus, AGENT_MANAGER_PATH, AGENT_MANAGER_IFACE)!;
	method_string(&manager, "Register", AGENT_IDENTIFIER)!;
}

fn void unregister_agent(Backend* b)
{
	Proxy manager = object_proxy(&b.bus, AGENT_MANAGER_PATH, AGENT_MANAGER_IFACE)!!;
	if (catch err = method_void(&manager, "Unregister"))
	{
	} // best effort: the bus may already be gone
}