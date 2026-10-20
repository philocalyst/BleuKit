// End-to-end run of the NetworkManager backend against tests/nm_mock.py on a
// private D-Bus daemon, with a fake sysfs root. Run by tests/run.sh, which sets:
//   BLEU_NETWORK_TEST_BUS   the bus address the mock serves
//   BLEU_NETWORK_TEST_ROOT  the fake root (sys/class/net/{eth0,wlan0}/...)
module bleu::network::nm_scenario_test @feat(LINUX);
import std::io, std::time, bleu::availability, bleu::error, bleu::network, bleu::observe, bleu::stream, bleu::rt::fs;

extern fn ZString getenv(ZString name) @cname("getenv");

alias StateCheck = fn bool(State* state);

fn String environment(ZString name)
{
	ZString value = getenv(name);
	if (!value) return "";
	return value.str_view();
}

// Latest state that satisfies `check`, waiting for newer generations as they come.
fn Snapshot{State}* await(Network* net, ulong seen, StateCheck check)
{
	ulong after = seen;
	while (true)
	{
		Snapshot{State}* snapshot = net.wait_after(after, time::ms(5000))!!;
		if (check(&snapshot.value)) return snapshot;
		after = snapshot.generation;
		snapshot.release();
	}
}

fn bool connected_to_office(State* state)
{
	return state.wifi.phase == CONNECTED && state.wifi.connected_ssid.label == "Office";
}

fn bool idle(State* state) => state.wifi.phase == IDLE;

fn bool has_network(State* state, String label)
{
	foreach (&network : state.wifi.networks)
	{
		if (network.ssid.label == label) return true;
	}
	return false;
}

fn AccessPoint* find(State* state, char[] ssid)
{
	foreach (&network : state.wifi.networks)
	{
		if (network::same_ssid(network.ssid.bytes, ssid)) return network;
	}
	return null;
}

fn Interface* interface_named(State* state, String name)
{
	foreach (&iface : state.interfaces)
	{
		if (iface.name == name) return iface;
	}
	return null;
}

fn void reads_the_picture() @test
{
	String bus  = environment("BLEU_NETWORK_TEST_BUS");
	String root = environment("BLEU_NETWORK_TEST_ROOT");
	assert(bus.len > 0 && root.len > 0, "the runner sets the bus and the sysfs root");
	Network* net = network::open(
		mem,
		{ .backend = NETWORKMANAGER, .poll = time::ms(100), .root = root, .bus_address = bus }
	)!!;
	defer net.close();
	assert(net.backend_name() == "networkmanager");
	assert(net.capability(WIFI_SECRET_PROMPT).ok(), "the secret agent answers passphrase requests");
	assert(net.capability(WIFI_CONNECT_PSK).ok());
	Snapshot{State}* first = await(net, 0, &has_networks);
	defer first.release();
	State* state = &first.value;

	// The visible networks: one per SSID, bytes kept, UTF-8 labels only where valid.
	assert(state.connectivity == FULL, "NetworkManager's Connectivity 4");
	assert(state.wifi.present && state.wifi.interface_name == "wlan0" && state.wifi.radio_enabled);
	assert(state.wifi.networks.len == 4, "four SSIDs; the hidden one is not listed");
	assert(has_network(state, "Cafe") && has_network(state, "Office") && has_network(state, "Guest-SAE"));
	AccessPoint* legacy = find(state, (char[])"\xff\xfeLegacy");
	assert(legacy != null, "a non-UTF-8 SSID is kept byte for byte");
	assert(legacy.ssid.label == "", "and gets no invented label");
	AccessPoint* office = find(state, (char[])"Office");
	assert(office.security == WPA2_PSK && office.band == GHZ_5 && (uint)office.frequency.value == 5180);
	assert(find(state, (char[])"Guest-SAE").security == WPA3_SAE, "an SAE-only network is WPA3");
	assert(find(state, (char[])"Cafe").security == OPEN);
	assert(office.quality.has_value && (float)office.quality.value > 0.89f, "strength 90 of 100");
	assert(!office.signal.has_value, "NetworkManager gives no dBm");
	assert(state.wifi.phase == IDLE && !state.wifi.connected_ssid.bytes.len, "not connected at the start");

	// Interfaces: Ethernet and Wi-Fi with sysfs link, speed and counters.
	Interface* eth = interface_named(state, "eth0");
	assert(eth != null && eth.kind == ETHERNET && eth.link == UP && eth.carrier.value);
	assert((int)eth.speed.value == 1000 && (ulong)eth.rx_bytes.value == 12345);
	assert(interface_named(state, "wlan0") != null, "the Wi-Fi interface is listed too");

	// A wrong passphrase: the device asks again, and the operation says so.
	ConnectOp* wrong = net.connect({ .ssid = (char[])"Office", .passphrase = "wrong words", .autoconnect = true })!!;
	assert(@catch(wrong.wait(time::sec(10))) == error::AUTH_REQUIRED, "a refused passphrase fails with AUTH_REQUIRED");
	wrong.release();
	Snapshot{State}* rejected = await(net, first.generation, &phase_failed);
	assert(rejected.value.wifi.failure == AUTH_REJECTED, "the failure says the passphrase was rejected");
	rejected.release();

	// The correct passphrase updates the saved profile and joins; the transitions are announced as events.
	Reader{Event}* events = net.subscribe()!!;
	defer events.release();
	ConnectOp* right = net.connect({ .ssid = (char[])"Office", .passphrase = "correct horse", .autoconnect = true })!!;
	Connected joined = right.wait(time::sec(10))!!;
	assert(joined.ssid.label == "Office"
		&& joined.interface_name == "wlan0", "the operation reports the joined network");
	right.release();
	bool announced = false;
	for (int seen = 0; seen < 64 && !announced; seen++)
	{
		if (try packet = events.next(time::ms(500)))
		{
			defer packet.release();
			announced = packet.value.kind == CONNECTION_CHANGED && packet.value.ssid.label == "Office";
		}
	}
	assert(announced, "a CONNECTION_CHANGED event names the network");
	Snapshot{State}* on = await(net, 0, &connected_to_office);
	assert(find(&on.value, (char[])"Office").in_use, "the network in use is marked");
	assert(on.value.primary_interface == "wlan0", "the primary connection runs on the Wi-Fi interface");
	on.release();

	// An open network needs no passphrase.
	ConnectOp* cafe = net.connect({ .ssid = (char[])"Cafe" })!!;
	cafe.wait(time::sec(10))!!;
	cafe.release();

	// Disconnect completes when the device reports DISCONNECTED.
	SettleOp* down = net.disconnect()!!;
	assert(down.wait(time::sec(10))!! == CHANGED, "a connected device disconnects");
	down.release();
	await(net, 0, &idle).release();
	SettleOp* again = net.disconnect()!!;
	assert(again.wait(time::sec(10))!! == ALREADY, "disconnecting twice is already done");
	again.release();

	// Saved networks: autoconnect and forget.
	SettleOp* quiet = net.set_autoconnect((char[])"Office", false)!!;
	assert(quiet.wait(time::sec(10))!! == CHANGED);
	quiet.release();
	SettleOp* same = net.set_autoconnect((char[])"Office", false)!!;
	assert(same.wait(time::sec(10))!! == ALREADY);
	same.release();
	SettleOp* forget = net.forget((char[])"Cafe")!!;
	assert(forget.wait(time::sec(10))!! == CHANGED);
	forget.release();
	SettleOp* missing = net.forget((char[])"Cafe")!!;
	assert(@catch(missing.wait(time::sec(10))) == NOT_FOUND, "forgetting twice is NOT_FOUND");
	missing.release();

	// Without a passphrase, NetworkManager asks the secret agent: the request is announced as an event,
	// and an answer completes the connection.
	ConnectOp* asked = net.connect({ .ssid = (char[])"Guest-SAE" })!!;
	ulong prompt     = await_prompt(events, "Guest-SAE");
	SettleOp* answer = net.supply_credentials(prompt, "sae-password")!!;
	assert(answer.wait(time::sec(10))!! == CHANGED, "the answer is delivered");
	answer.release();
	asked.wait(time::sec(10))!!;
	asked.release();

	// A refused prompt fails the connection with AUTH_REQUIRED.
	ConnectOp* refused = net.connect({ .ssid = (char[])"Guest-SAE" })!!;
	ulong second       = await_prompt(events, "Guest-SAE");
	SettleOp* refusal  = net.cancel_credentials(second)!!;
	assert(refusal.wait(time::sec(10))!! == CHANGED, "the refusal is delivered");
	refusal.release();
	assert(@catch(refused.wait(time::sec(10))) == error::AUTH_REQUIRED, "a refused prompt fails with AUTH_REQUIRED");
	refused.release();
	SettleOp* stale = net.supply_credentials(second, "sae-password")!!;
	assert(@catch(stale.wait(time::sec(10))) == NOT_FOUND, "an answered prompt is gone");
	stale.release();

	// SAE with its password, and the non-UTF-8 network by its bytes.
	ConnectOp* sae = net.connect({ .ssid = (char[])"Guest-SAE", .passphrase = "sae-password" })!!;
	sae.wait(time::sec(10))!!;
	sae.release();
	ConnectOp* legacy_join = net.connect({ .ssid = (char[])"\xff\xfeLegacy", .passphrase = "legacy-pass" })!!;
	legacy_join.wait(time::sec(10))!!;
	legacy_join.release();

	// The radio goes off and on again.
	SettleOp* off = net.set_radio(false)!!;
	assert(off.wait(time::sec(10))!! == CHANGED);
	off.release();
	Snapshot{State}* dark = await(net, 0, &radio_off);
	assert(!dark.value.wifi.radio_enabled);
	dark.release();
	SettleOp* on_again = net.set_radio(true)!!;
	assert(on_again.wait(time::sec(10))!! == CHANGED);
	on_again.release();

	// A scan completes when NetworkManager reports a new LastScan.
	SettleOp* scan = net.scan()!!;
	assert(scan.wait(time::sec(10))!! == CHANGED, "the scan finishes");
	scan.release();

	// Counters follow the sysfs files.
	fs::write_text(string::tformat("%s/sys/class/net/eth0/statistics/rx_bytes", root), "99999")!!;
	net.refresh()!!;
	Snapshot{State}* counted = await(net, 0, &eth_counted);
	counted.release();
}

// The id of the next CREDENTIALS_WANTED event for `label`.
fn ulong await_prompt(Reader{Event}* events, String label)
{
	for (int seen = 0; seen < 64; seen++)
	{
		Snapshot{Event}* packet = events.next(time::sec(10))!!;
		defer packet.release();
		if (packet.value.kind == CREDENTIALS_WANTED && packet.value.ssid.label == label) return packet.value.request;
	}
	unreachable("a CREDENTIALS_WANTED event names the network");
}

fn bool has_networks(State* state) => state.wifi.networks.len > 0;

fn bool phase_failed(State* state) => state.wifi.phase == FAILED;

fn bool radio_off(State* state) => !state.wifi.radio_enabled;

fn bool eth_counted(State* state)
{
	Interface* eth = interface_named(state, "eth0");
	return eth != null && eth.rx_bytes.has_value && (ulong)eth.rx_bytes.value == 99999;
}

fn void missing_bus_does_not_open() @test
{
	assert(@catch(
		network::open(mem, { .backend = NETWORKMANAGER, .bus_address = "unix:path=/nonexistent/bus" })
	) == error::UNAVAILABLE, "no bus, no service");
}

// The fixture: a service on the private bus, polling every 100 ms.
fn Network* open_fixture()
{
	return network::open(
		mem,
		{
			.backend = NETWORKMANAGER,
			.poll = time::ms(100),
			.root = environment("BLEU_NETWORK_TEST_ROOT"),
			.bus_address = environment("BLEU_NETWORK_TEST_BUS"),
		}
	)!!;
}

// Switch a fault of the mock on ("1") or off ("0").
fn void set_fault(String name, String value) @local
{
	fs::write_text(string::tformat("%s/%s", environment("BLEU_NETWORK_TEST_FAULTS"), name), value)!!;
}

fn String eth_rx_path() @local => string::tformat("%s/sys/class/net/eth0/statistics/rx_bytes", environment("BLEU_NETWORK_TEST_ROOT"));

fn bool eth_rx_is_20001(State* state)
{
	Interface* eth = interface_named(state, "eth0");
	return eth != null && eth.rx_bytes.has_value && (ulong)eth.rx_bytes.value == 20001;
}

fn bool eth_rx_is_20002(State* state)
{
	Interface* eth = interface_named(state, "eth0");
	return eth != null && eth.rx_bytes.has_value && (ulong)eth.rx_bytes.value == 20002;
}

// Whether a NETWORKS_CHANGED event comes in during a short wait.
fn bool networks_changed(Reader{Event}* events)
{
	for (int seen = 0; seen < 10; seen++)
	{
		if (try packet = events.next(time::ms(50)))
		{
			defer packet.release();
			if (packet.value.kind == NETWORKS_CHANGED) return true;
		}
	}
	return false;
}

// Whether the event `kind` about `request` comes in before a long wait runs out.
fn bool await_event(Reader{Event}* events, EventKind kind, ulong request)
{
	for (int seen = 0; seen < 64; seen++)
	{
		Snapshot{Event}* packet = events.next(time::sec(10))!!;
		defer packet.release();
		if (packet.value.kind == kind && packet.value.request == request) return true;
	}
	return false;
}

// D2: an access point that left between the list and its read is not listed; the picture is fresh.
fn void an_access_point_that_left_is_not_listed() @test
{
	Network* net = open_fixture();
	defer net.close();
	Snapshot{State}* first = await(net, 0, &has_networks);
	defer first.release();
	Reader{Event}* events = net.subscribe()!!;
	defer events.release();
	defer set_fault("vanish-ap", "0");
	set_fault("vanish-ap", "1");
	defer fs::write_text(eth_rx_path(), "12345")!!;
	fs::write_text(eth_rx_path(), "20002")!!;
	net.refresh()!!;
	Snapshot{State}* read = await(net, first.generation, &eth_rx_is_20002);
	defer read.release();
	assert(read.value.wifi.networks.len == 4, "the access point that left is skipped, the others stay");
	assert(!read.value.stale.wifi, "the read is fresh: nothing was kept");
	assert(!networks_changed(events), "and no network was announced as removed or added");
}

// D2: one failed sub-read keeps the previous networks, flagged stale, with no spurious events.
fn void a_failed_sub_read_keeps_the_previous_networks() @test
{
	Network* net = open_fixture();
	defer net.close();
	Snapshot{State}* first = await(net, 0, &has_networks);
	defer first.release();
	Reader{Event}* events = net.subscribe()!!;
	defer events.release();
	defer set_fault("wifi-fail", "0");
	set_fault("wifi-fail", "1");
	defer fs::write_text(eth_rx_path(), "12345")!!;
	fs::write_text(eth_rx_path(), "20001")!!;
	net.refresh()!!;
	Snapshot{State}* kept = await(net, first.generation, &eth_rx_is_20001);
	defer kept.release();
	assert(kept.value.stale.wifi, "the failed read is recorded on the picture");
	assert(kept.value.wifi.networks.len == 4, "the previous networks are kept, not blanked");
	assert(has_network(&kept.value, "Office") && has_network(&kept.value, "Cafe"));
	assert(!networks_changed(events), "no network was announced as removed or added");
}

// D7: a read whose Wi-Fi part failed settles no request from its values: the radio is off on
// the bus, but only a good read says so.
fn void a_failed_read_settles_no_request() @test
{
	Network* net = open_fixture();
	defer net.close();
	Snapshot{State}* first = await(net, 0, &has_networks);
	defer first.release();
	defer set_fault("wifi-fail", "0");
	set_fault("wifi-fail", "1");
	SettleOp* off = net.set_radio(false)!!;
	assert(@catch(off.wait(time::ms(600))) == TIMEOUT, "no good read yet: the request keeps waiting");
	set_fault("wifi-fail", "0");
	assert(off.wait(time::sec(10))!! == CHANGED, "a good read settles it");
	off.release();
	SettleOp* on_again = net.set_radio(true)!!;
	assert(on_again.wait(time::sec(10))!! == CHANGED);
	on_again.release();
}

// D9: a prompt that NetworkManager supersedes is withdrawn by its id, before the new prompt.
fn void a_superseded_prompt_is_withdrawn() @test
{
	Network* net = open_fixture();
	defer net.close();
	Snapshot{State}* first = await(net, 0, &has_networks);
	defer first.release();
	Reader{Event}* events = net.subscribe()!!;
	defer events.release();
	ConnectOp* first_try = net.connect({ .ssid = (char[])"Guest-SAE" })!!;
	ulong older = await_prompt(events, "Guest-SAE");
	ConnectOp* second_try = net.connect({ .ssid = (char[])"Guest-SAE" })!!;
	assert(await_event(events, CREDENTIALS_WITHDRAWN, older), "the superseded prompt is withdrawn");
	ulong newer = await_prompt(events, "Guest-SAE");
	SettleOp* answer = net.supply_credentials(newer, "sae-password")!!;
	assert(answer.wait(time::sec(10))!! == CHANGED, "the answer is delivered");
	answer.release();
	second_try.wait(time::sec(10))!!;
	second_try.release();
	first_try.wait(time::sec(10))!!;
	first_try.release();
	SettleOp* down = net.disconnect()!!;
	assert(down.wait(time::sec(10))!! == CHANGED);
	down.release();
	await(net, 0, &idle).release();
}

// D10: when NetworkManager refuses the secret agent, the capability says so instead of offering prompts.
fn void a_refused_agent_withdraws_the_prompt_capability() @test
{
	defer set_fault("no-agent", "0");
	set_fault("no-agent", "1");
	Network* net = open_fixture();
	defer net.close();
	assert(!net.capability(WIFI_SECRET_PROMPT).ok(), "no prompt is offered");
	assert(net.capability(WIFI_SECRET_PROMPT).reason == availability::Reason.PERMISSION_NEEDED, "and the reason is given");
}

// D16: forgetting a network deletes every saved profile of it, so a second forget finds none.
fn void every_saved_profile_of_a_network_is_forgotten() @test
{
	Network* net = open_fixture();
	defer net.close();
	SettleOp* forget = net.forget((char[])"Twin")!!;
	assert(forget.wait(time::sec(10))!! == CHANGED, "both saved profiles are deleted");
	forget.release();
	SettleOp* again = net.forget((char[])"Twin")!!;
	assert(@catch(again.wait(time::sec(10))) == NOT_FOUND, "no saved profile is left");
	again.release();
}
