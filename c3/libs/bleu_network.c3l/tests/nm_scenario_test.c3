// End-to-end run of the NetworkManager backend against tests/nm_mock.py on a
// private D-Bus daemon, with a fake sysfs root. Run by tests/run.sh, which sets:
//   BLEU_NETWORK_TEST_BUS   the bus address the mock serves
//   BLEU_NETWORK_TEST_ROOT  the fake root (sys/class/net/{eth0,wlan0}/...)
module bleu::network::nm_scenario_test @feat(LINUX);
import std::io, std::time, bleu::error, bleu::network, bleu::observe, bleu::stream, bleu::rt::fs;

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
	String bus = environment("BLEU_NETWORK_TEST_BUS");
	String root = environment("BLEU_NETWORK_TEST_ROOT");
	assert(bus.len > 0 && root.len > 0, "the runner sets the bus and the sysfs root");
	Network* net = network::open(mem, { .backend = NETWORKMANAGER, .poll = time::ms(100), .root = root, .bus_address = bus })!!;
	defer net.close();
	assert(net.backend_name() == "networkmanager");
	assert(net.capability(WIFI_SECRET_PROMPT).reason == UNSUPPORTED_BACKEND, "no secret agent yet, and it says why");
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
	fault wrong_fault = @catch(wrong.wait(time::sec(10)));
	io::printfn("DEBUG wrong passphrase fault: %s status=%d detail=%s", wrong_fault, error::last().status.ordinal, error::last().message());
	assert(wrong_fault == error::AUTH_REQUIRED, "a refused passphrase fails with AUTH_REQUIRED");
	wrong.release();
	Snapshot{State}* rejected = await(net, first.generation, &phase_failed);
	assert(rejected.value.wifi.failure == AUTH_REJECTED, "the failure says the passphrase was rejected");
	rejected.release();

	// The correct passphrase updates the saved profile and joins.
	ConnectOp* right = net.connect({ .ssid = (char[])"Office", .passphrase = "correct horse", .autoconnect = true })!!;
	Connected joined = right.wait(time::sec(10))!!;
	assert(joined.ssid.label == "Office" && joined.interface_name == "wlan0", "the operation reports the joined network");
	right.release();
	Snapshot{State}* on = await(net, 0, &connected_to_office);
	assert(find(&on.value, (char[])"Office").in_use, "the network in use is marked");
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

	// Connecting without a passphrase to a network with no saved profile.
	ConnectOp* needs = net.connect({ .ssid = (char[])"Guest-SAE" })!!;
	assert(@catch(needs.wait(time::sec(10))) == error::AUTH_REQUIRED, "a passphrase is needed and none was given");
	needs.release();

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
	assert(@catch(network::open(mem, { .backend = NETWORKMANAGER, .bus_address = "unix:path=/nonexistent/bus" })) == error::UNAVAILABLE, "no bus, no service");
}
