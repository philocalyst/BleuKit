module bleu::network::sysfs_test @feat(LINUX);
import std::io::path, std::time::clock, bleu::network, bleu::network::sysfs, bleu::network::sysfs_convert, bleu::rt::fs;

fn void operstate_words() @test
{
	@pool()
	{
		assert(sysfs_convert::link_from_operstate("up") == UP);
		assert(sysfs_convert::link_from_operstate("dormant") == DORMANT);
		assert(sysfs_convert::link_from_operstate("lowerlayerdown") == DOWN);
		assert(sysfs_convert::link_from_operstate("unknown") == UNKNOWN);
	};
}

fn void unknown_speed_and_negative_counters_are_empty() @test
{
	@pool()
	{
		assert(sysfs_convert::speed_from_sysfs(-1).has_value == false);
		assert(sysfs_convert::speed_from_sysfs(1000).value == (Mbps)1000);
		assert(sysfs_convert::counter_from_sysfs(-5).has_value == false);
		assert(sysfs_convert::carrier_from_sysfs(0).value == false);
	};
}

// A fake sysfs tree: one wired interface that is up, one that is down with no carrier.
fn String fake_tree(String stem) @local
{
	String root = string::tformat("/tmp/bleu-network-%s-%d", stem, clock::now());
	String up   = string::tformat("%s/sys/class/net/eth0", root);
	String down = string::tformat("%s/sys/class/net/wlan1", root);
	path::mkdir((Path)string::tformat("%s/statistics", up), true)!!;
	path::mkdir((Path)string::tformat("%s/statistics", down), true)!!;
	fs::write_text(string::tformat("%s/operstate", up), "up")!!;
	fs::write_text(string::tformat("%s/carrier", up), "1")!!;
	fs::write_text(string::tformat("%s/speed", up), "1000")!!;
	fs::write_text(string::tformat("%s/statistics/rx_bytes", up), "12345")!!;
	fs::write_text(string::tformat("%s/statistics/tx_bytes", up), "678")!!;
	fs::write_text(string::tformat("%s/operstate", down), "down")!!;
	fs::write_text(string::tformat("%s/speed", down), "-1")!!;
	return root;
}

fn void reads_an_interface_from_its_directory() @test
{
	@pool()
	{
		String root   = fake_tree("read");
		Interface eth = sysfs::read_interface(tmem, root, "eth0", ETHERNET);
		assert(eth.name == "eth0" && eth.kind == ETHERNET && eth.link == UP);
		assert(eth.carrier.value == true, "carrier 1");
		assert((uint)eth.speed.value == 1000);
		assert((ulong)eth.rx_bytes.value == 12345 && (ulong)eth.tx_bytes.value == 678);
	};
}

fn void a_down_interface_leaves_fields_empty() @test
{
	@pool()
	{
		String root    = fake_tree("down");
		Interface wlan = sysfs::read_interface(tmem, root, "wlan1", WIFI);
		assert(wlan.link == DOWN);
		assert(!wlan.carrier.has_value, "carrier is unreadable while down: empty, not false");
		assert(!wlan.speed.has_value, "speed -1 is unknown");
		assert(!wlan.rx_bytes.has_value, "no statistics directory content: empty");
	};
}

// D27: a name that is not one path element is never read; "../net/eth0" is eth0 under another name.
fn void a_name_that_leaves_the_class_directory_is_not_read() @test
{
	@pool()
	{
		String root       = fake_tree("traverse");
		Interface escaped = sysfs::read_interface(tmem, root, "../net/eth0", ETHERNET);
		assert(escaped.link == UNKNOWN, "the traversal is refused, so nothing is read");
		assert(!escaped.carrier.has_value && !escaped.speed.has_value);
		assert(!sysfs_convert::valid_interface_name("../eth0"), "a parent directory");
		assert(!sysfs_convert::valid_interface_name("a/b"), "a separator");
		assert(sysfs_convert::valid_interface_name("eth0"), "a kernel name");
	};
}