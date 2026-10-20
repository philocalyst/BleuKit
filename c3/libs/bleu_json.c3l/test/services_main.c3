// Serialises a sample of each finished service's state with the bleu_json
// reflective writer, one line per state: "<service> <json>". The lines are
// checked by check_services.py with python3's json module.
module services_main;
import std::io, std::collections::maybe, std::time;
import bleu::json, bleu::unit, bleu::availability, bleu::battery, bleu::brightness, bleu::network;

// Fixed arrays are returned by value; the slices that point at them are made in
// `main`, where the storage outlives every serialisation.
fn battery::Source[2] battery_sources()
{
	return {
		{
			.id = "BAT0",
			.kind = battery::Kind.BATTERY,
			.present = true,
			.state = battery::ChargeState.DISCHARGING,
			.charge = maybe::value{Level}((Level)0.82f),
			.power = maybe::value{MilliWatt}((MilliWatt)-7400),
			.time_to_empty = maybe::value{Duration}((Duration)5_400_000_000),
			.energy = maybe::value{MilliWattHour}((MilliWattHour)41000),
			.energy_full = maybe::value{MilliWattHour}((MilliWattHour)50000),
			.energy_design = maybe::value{MilliWattHour}((MilliWattHour)55000),
			.health = maybe::value{Level}((Level)0.909f),
			.cycles = maybe::value{uint}((uint)312),
			.temperature = maybe::value{Celsius}((Celsius)31.5f),
			.chemistry = battery::Chemistry.LITHIUM_ION,
			.vendor = "SMP",
			.model = "DELL 0K3",
			.serial = "1234",
		},
		{
			.id = "AC",
			.kind = battery::Kind.MAINS,
			.present = true,
			.state = battery::ChargeState.UNKNOWN,
		},
	};
}

fn brightness::Control[2] brightness_controls()
{
	return {
		{
			.mechanism = brightness::Mechanism.BACKLIGHT,
			.readable = true,
			.writable = true,
			.availability = availability::YES,
			.level = maybe::value{Level}((Level)0.4f),
			.raw = maybe::value{long}((long)4096),
			.raw_min = 0,
			.raw_max = 96000,
		},
		{
			.mechanism = brightness::Mechanism.GAMMA,
			.readable = false,
			.writable = false,
			.availability = availability::no(availability::Reason.DEGRADED, "software only"),
			.raw_min = 0,
			.raw_max = 0,
		},
	};
}

fn network::AccessPoint[1] network_points(char[] home)
{
	return {
		{
			.ssid = { .bytes = home, .label = "Home" },
			.bssid = "",
			.frequency = maybe::value{MegaHertz}((MegaHertz)5180),
			.signal = maybe::value{Dbm}((Dbm)-52),
			.band = network::Band.GHZ_5,
			.security = network::Security.WPA2_PSK,
			.in_use = true,
			.known = true,
			.autoconnect = true,
		},
	};
}

fn network::Interface[1] network_interfaces()
{
	return {
		{
			.name = "wlan0",
			.kind = network::InterfaceKind.WIFI,
			.link = network::LinkState.UP,
			.carrier = maybe::value{bool}(true),
			.rx_bytes = maybe::value{Bytes}((Bytes)123456789),
		},
	};
}

fn network::State network_state(network::AccessPoint[] points, network::Interface[] interfaces, char[] home)
{
	network::Wifi wifi = {
		.present = true,
		.interface_name = "wlan0",
		.radio_enabled = true,
		.ssid_visible = true,
		.phase = network::ConnectionPhase.CONNECTED,
		.connected_ssid = { .bytes = home, .label = "Home" },
		.signal = maybe::value{Dbm}((Dbm)-52),
		.networks = points,
	};
	return {
		.connectivity = network::Connectivity.FULL,
		.location = network::LocationAccess.NOT_APPLICABLE,
		.primary_interface = "wlan0",
		.wifi = wifi,
		.interfaces = interfaces,
	};
}

fn void main()
{
	battery::Source[2] sources = battery_sources();
	battery::State battery_state = { .on_mains = true, .sources = sources[..], .adapter_watts = maybe::value{uint}((uint)65) };
	io::printfn("battery %s", json::to_json(mem, battery_state)!!);

	brightness::Control[2] controls = brightness_controls();
	brightness::Device[1] devices = {
		{ .id = "eDP-1", .name = "Built-in panel", .kind = brightness::DeviceKind.PANEL, .controls = controls[..] },
	};
	brightness::State brightness_state = { .devices = devices[..] };
	io::printfn("brightness %s", json::to_json(mem, brightness_state)!!);

	char[] home = (char[])"Home";
	network::AccessPoint[1] points = network_points(home);
	network::Interface[1] interfaces = network_interfaces();
	io::printfn("network %s", json::to_json(mem, network_state(points[..], interfaces[..], home))!!);
}
