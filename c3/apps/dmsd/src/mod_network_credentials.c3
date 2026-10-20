<*
 The `network.credentials` topic: one `CredentialPrompt` (DMS `network/types.go:254-267`)
 for every passphrase Bleu asks for.

 Bleu reports a request for a passphrase as an event (`CREDENTIALS_WANTED`, with the
 network's name and an id), not as state, so the topic is an event topic: each prompt
 is sent once to the subscribers connected at that moment, and nothing is kept. A
 `CredentialPump` thread reads the event stream of the service and publishes.

 DMS sends the prompt of its own NetworkManager agent (`agent_networkmanager.go`
 `Ask`, buildFieldsInfo). For a Wi-Fi passphrase the field is `psk`, labelled
 "Password" and secret. The fields Bleu does not know (the reason the network asked
 again, the connection's id and uuid) are empty or `required`, DMS's default.
*>
module dmsd::network_credentials;
import std::thread, std::atomic, std::time, bleu::network, bleu::stream, bleu::observe, bleu::ipc, bleu::error, bleu::json, bleu::rt::foreign, dmsd::contract, dmsd::wire;

// How often the pump checks whether it was asked to stop, while no prompt is waiting.
const Duration POLL_INTERVAL = (Duration)100_000;
// The fields of a Wi-Fi passphrase prompt, and their labels (DMS buildFieldsInfo, `802-11-wireless-security`).
const String[1] PSK_FIELDS    = { "psk" };
const String WIFI_CONNECTION  = "802-11-wireless";
const String WIFI_SECURITY    = "802-11-wireless-security";
const String PSK_LABEL        = "Password";
// DMS's `reasonFromFlags` default (agent_networkmanager.go:1126-1143): the secret is required.
const String REASON_REQUIRED  = "required";

<*
 Reads the service's events on its own thread and publishes each prompt on `topic`.
 `start` and `stop` run on the module's thread; the thread only reads and publishes.
*>
struct CredentialPump
{
	stream::Reader{network::Event}* reader;
	Thread thread;
	Atomic{bool} stopping;
	bool started;
	String name;
	ipc::Topic* topic;
}

<*
 Start the pump's thread. The reader is the service's event stream; the pump owns it from here on.

 @param name : "Module and topic name, for diagnostics"
 @param topic : "The event topic, registered before the server starts"
 @param reader : "The service's event stream, from `subscribe`"
 @return? error::BACKEND_FAILURE : "The thread could not be started"
*>
fn void? CredentialPump.start(&self, String name, ipc::Topic* topic, stream::Reader{network::Event}* reader)
{
	self.name = name;
	self.topic = topic;
	self.reader = reader;
	self.thread.create(&pump_main, self)!;
	self.started = true;
}

<*
 Stop the thread, wait until it has returned, and release the event stream. Called
 after the service's event source is still open, and before the service is closed.
*>
fn void CredentialPump.stop(&self)
{
	if (self.started)
	{
		self.stopping.store(true);
		self.thread.join()!!;
		self.started = false;
	}
	self.reader.release();
}

// The thread's entry point. The temporary allocator is set up first (see bleu::rt::foreign).
fn int pump_main(void* arg) @private
{
	CredentialPump* pump = (CredentialPump*)arg;
	foreign::@foreign_entry()
	{
		pump.run();
	};
	return 0;
}

// Read events until stopped. A timeout only means nothing was asked for; a closed stream ends the thread.
fn void CredentialPump.run(&self)
{
	while (!self.stopping.load())
	{
		observe::Snapshot{network::Event}*? next = self.reader.next(POLL_INTERVAL);
		if (catch err = next)
		{
			if (err == error::DISCONNECTED) return;
		}
		else
		{
			self.publish(next);
		}
	}
}

// Publish a `CREDENTIALS_WANTED` event as a prompt. The packet is released here. Other kinds are not prompts.
fn void CredentialPump.publish(&self, observe::Snapshot{network::Event}* packet)
{
	defer packet.release();
	if (packet.value.kind != network::EventKind.CREDENTIALS_WANTED) return;
	@pool()
	{
		if (try line = render_prompt(tmem, &packet.value))
		{
			if (catch self.topic.publish_event(line)) contract::note("%s: prompt not sent", self.name);
		}
		else
		{
			contract::warn("%s: prompt not rendered", self.name);
		}
	};
}

<*
 A `CredentialPrompt` as one JSON line in `allocator` (types.go:254-267, key order as declared).
 @return "The line, in `allocator`"
*>
fn String? render_prompt(Allocator allocator, network::Event* event)
{
	wire::Line line;
	line.begin(allocator);
	json::JsonWriter* w = &line.writer;
	String ssid = event.ssid.label;
	w.begin_object()!;
	wire::key_string(w, "token", string::tformat("%d", event.request))!;
	wire::key_string(w, "name", ssid)!;
	wire::key_string(w, "ssid", ssid)!;
	wire::key_string(w, "connType", WIFI_CONNECTION)!;
	wire::key_string(w, "vpnService", "")!;
	wire::key_string(w, "setting", WIFI_SECURITY)!;
	wire::key_strings(w, "fields", PSK_FIELDS[..])!;
	w.key("fieldsInfo")!;
	w.begin_array()!;
	w.begin_object()!;
	wire::key_string(w, "name", PSK_FIELDS[0])!;
	wire::key_string(w, "label", PSK_LABEL)!;
	wire::key_bool(w, "isSecret", true)!;
	w.end_object()!;
	w.end_array()!;
	w.key("hints")!;
	w.begin_array()!;
	w.end_array()!;
	wire::key_string(w, "reason", REASON_REQUIRED)!;
	wire::key_string(w, "connectionId", "")!;
	wire::key_string(w, "connectionUuid", "")!;
	w.end_object()!;
	return line.finish();
}
