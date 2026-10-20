<*
 The `network` module: DMS's Wi-Fi methods, the `network` state topic and the
 `network.credentials` prompt topic, over `bleu::network`.

 Served: `network.getState`, `wifi.networks`, `wifi.scan`, `wifi.connect`,
 `wifi.disconnect`, `wifi.forget`, `wifi.toggle`, `wifi.enable`, `wifi.disable`,
 `wifi.setAutoconnect`, `info`, `credentials.submit`, `credentials.cancel`. Every other
 DMS method of the prefix answers `not supported` (`mod_network_unsupported.c3`).
 Topics: `network` (the `NetworkState`, on every change) and `network.credentials`
 (a `CredentialPrompt` for each passphrase Bleu asks for; `mod_network_credentials.c3`).

 Source of every shape and rule: DMS `core/internal/server/network/` (types.go,
 handlers.go, manager.go, agent_networkmanager.go) at 8be08999, and `server.go:432,579-595`
 for the capability and the two subscriptions. Deviations are listed in docs/DMSD.md.
*>
module dmsd::network_mod;
import bleu::network, bleu::observe, bleu::ipc, bleu::stream, dmsd::contract, dmsd::network_actions, dmsd::network_credentials, dmsd::network_state, dmsd::network_unsupported;

const String[2] TOPICS       = { "network", "network.credentials" };
const String[1] CAPABILITIES = { "network" };

<* The module's runtime state. Allocated in `start`, freed in `stop`. *>
struct NetworkModule
{
	network::Network* service;
	String backend_name;
	contract::StatePump state_pump;
	network_credentials::CredentialPump prompts;
	observe::WatchId{network::State} watch_id;
}

<*
 The newest `NetworkState` as one JSON line in `allocator`. Fails when the service has
 published nothing yet, which `open` rules out once the module has started.
*>
fn String? NetworkModule.current(&self, Allocator allocator)
{
	observe::Snapshot{network::State}* snapshot = self.service.latest()!;
	defer snapshot.release();
	return network_state::render_state(allocator, self.backend_name, &snapshot.value);
}

// Encodes the newest state for the `network` topic.
fn String? encode_state(void* context, Allocator allocator)
{
	NetworkModule* m = (NetworkModule*)context;
	return m.current(allocator);
}

// Listener: runs on the service's thread. It only marks the pump dirty.
fn void on_state(void* context, observe::Snapshot{network::State}* snapshot)
{
	contract::StatePump* pump = (contract::StatePump*)context;
	pump.notify();
}

<*
 Start the network module, or report why not and return false. The backend is absent when
 NetworkManager is not on the bus (`bleu::network` answers UNAVAILABLE), and then the
 methods are not registered and the capability is not advertised.
*>
fn bool start(contract::Context* context, contract::Module* self)
{
	network::Options options = { .root = context.options.fake_root };
	network::Network* service;
	if (try opened = network::open(context.allocator, options))
	{
		service = opened;
	}
	else
	{
		contract::warn("network: not started: %s", contract::failure_text("no backend"));
		return false;
	}
	stream::Reader{network::Event}* events;
	if (try subscribed = service.subscribe())
	{
		events = subscribed;
	}
	else
	{
		service.close();
		contract::warn("network: not started: %s", contract::failure_text("cannot subscribe to events"));
		return false;
	}
	NetworkModule* m = alloc::new(context.allocator, NetworkModule);
	m.service = service;
	m.backend_name = service.backend_name();
	ipc::Topic* state_topic = context.server.register_topic("network")!!;
	ipc::Topic* prompt_topic = context.server.register_topic("network.credentials")!!;
	context.server.register_method("network.getState", &handle_get_state, m)!!;
	context.server.register_method("network.wifi.networks", &network_actions::handle_wifi_networks, service)!!;
	context.server.register_method("network.wifi.scan", &network_actions::handle_wifi_scan, service)!!;
	context.server.register_method("network.wifi.connect", &network_actions::handle_wifi_connect, service)!!;
	context.server.register_method("network.wifi.disconnect", &network_actions::handle_wifi_disconnect, service)!!;
	context.server.register_method("network.wifi.forget", &network_actions::handle_wifi_forget, service)!!;
	context.server.register_method("network.wifi.toggle", &network_actions::handle_wifi_toggle, service)!!;
	context.server.register_method("network.wifi.enable", &network_actions::handle_wifi_enable, service)!!;
	context.server.register_method("network.wifi.disable", &network_actions::handle_wifi_disable, service)!!;
	context.server.register_method("network.wifi.setAutoconnect", &network_actions::handle_wifi_set_autoconnect, service)!!;
	context.server.register_method("network.info", &network_actions::handle_info, service)!!;
	context.server.register_method("network.credentials.submit", &network_actions::handle_credentials_submit, service)!!;
	context.server.register_method("network.credentials.cancel", &network_actions::handle_credentials_cancel, service)!!;
	network_unsupported::register_unsupported(context.server);
	m.state_pump.start("network", state_topic, &encode_state, m)!!;
	m.prompts.start("network.credentials", prompt_topic, events)!!;
	m.watch_id = service.watch(&on_state, &m.state_pump);
	self.state = m;
	return true;
}

<* Stop the module: no more publications, then the service is closed. The server has stopped already. *>
fn void stop(contract::Context* context, contract::Module* self)
{
	NetworkModule* m = (NetworkModule*)self.state;
	m.service.unwatch(m.watch_id)!!;
	m.state_pump.stop();
	m.state_pump.free();
	m.prompts.stop();
	m.service.close();
	alloc::free(context.allocator, m);
}

<* The module's descriptor for `main`. A global constant, so its slices point at static data. *>
const contract::Module DESCRIPTOR = {
	.name = "network",
	.start = &start,
	.stop = &stop,
	.topics = TOPICS[..],
	.capabilities = CAPABILITIES[..]
};

fn contract::Module descriptor() => DESCRIPTOR;

// `network.getState` (handlers.go:152-154): the newest state.
fn void handle_get_state(void* context, ipc::Call* call)
{
	NetworkModule* m = (NetworkModule*)context;
	@pool()
	{
		if (try line = m.current(tmem))
		{
			call.respond_raw(line);
		}
		else
		{
			call.respond_error(contract::failure_text("cannot read the network state"));
		}
	};
}
