module bleu::network::publish_test;
import bleu::network, bleu::equal;

// D2: the parts a failed read keeps are deep copies, and they say they are old.
fn void a_stale_picture_keeps_every_part_as_a_copy() @test
{
	@pool()
	{
		Interface[] interfaces = alloc::new_array(tmem, Interface, 1);
		interfaces[0] = { .name = "wlan0".copy(tmem), .kind = WIFI, .link = UP };
		AccessPoint[] networks = alloc::new_array(tmem, AccessPoint, 1);
		networks[0] = {
			.ssid = network::make_ssid(tmem, (char[])"Office"),
			.bssid = "aa:bb:cc:dd:ee:ff".copy(tmem),
			.security = WPA2_PSK,
		};
		State previous = {
			.primary_interface = "wlan0".copy(tmem),
			.wifi = {
				.present = true,
				.interface_name = "wlan0".copy(tmem),
				.connected_ssid = network::make_ssid(tmem, (char[])"Office"),
				.networks = networks,
			},
			.interfaces = interfaces,
		};
		State kept = network::stale_picture(tmem, &previous);
		assert(equal::deep(kept.wifi.networks, previous.wifi.networks), "the networks are kept");
		assert(equal::deep(kept.interfaces, previous.interfaces), "the interfaces are kept");
		assert(kept.primary_interface == "wlan0", "and the primary interface");
		assert(kept.wifi.networks.ptr != previous.wifi.networks.ptr, "a copy: the previous picture may be released");
		assert(kept.stale.primary && kept.stale.wifi && kept.stale.interfaces, "each part says it may be old");
	};
}