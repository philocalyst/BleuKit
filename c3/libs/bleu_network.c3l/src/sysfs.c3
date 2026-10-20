<*
 Reading `/sys/class/net/<interface>` into an `Interface`: link state, carrier,
 speed and traffic counters. The meaning of each file is in `sysfs_convert.c3`.
 A missing attribute is normal (drivers expose what they can) and leaves the
 corresponding field empty.
*>
module bleu::network::sysfs @feat(LINUX);
import bleu::network, bleu::rt::fs, bleu::network::sysfs_convert;

const String NET_DIR         = "/sys/class/net";
const usz ATTRIBUTE_CAPACITY = 64;

<*
 The interface `name` under `root`, as the kernel shows it. Reading never
 fails: an attribute that cannot be read just leaves its field empty.

 @param allocator : "Allocator for the name"
*>
fn Interface read_interface(Allocator allocator, String root, String name, InterfaceKind kind)
{
	@pool()
	{
		String dir = string::tformat("%s%s/%s", root, NET_DIR, name);
		Interface found = {
			.name = name.copy(allocator),
			.kind = kind,
			.link = UNKNOWN,
		};
		// A name that is not one path element is never read (it could leave the class directory).
		if (!sysfs_convert::valid_interface_name(name)) return found;
		char[ATTRIBUTE_CAPACITY] operstate;
		if (try text = fs::read_trimmed(string::tformat("%s/operstate", dir), operstate[..]))
		{
			found.link = sysfs_convert::link_from_operstate(text);
		}
		if (try carrier = fs::read_integer(string::tformat("%s/carrier", dir)))
		{
			found.carrier = sysfs_convert::carrier_from_sysfs(carrier);
		}
		if (try speed = fs::read_integer(string::tformat("%s/speed", dir)))
		{
			found.speed = sysfs_convert::speed_from_sysfs(speed);
		}
		if (try rx = fs::read_integer(string::tformat("%s/statistics/rx_bytes", dir)))
		{
			found.rx_bytes = sysfs_convert::counter_from_sysfs(rx);
		}
		if (try tx = fs::read_integer(string::tformat("%s/statistics/tx_bytes", dir)))
		{
			found.tx_bytes = sysfs_convert::counter_from_sysfs(tx);
		}
		return found;
	};
}