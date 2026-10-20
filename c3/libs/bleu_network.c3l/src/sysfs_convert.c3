<*
 Turning `/sys/class/net/<iface>` attributes into Bleu's types. Pure: the
 caller reads the files, this file decides what the numbers and words mean.

 Source: Documentation/ABI/testing/sysfs-class-net (carrier, operstate, speed)
 and Documentation/ABI/testing/sysfs-class-net-statistics (rx_bytes, tx_bytes),
 https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-class-net and
 https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-class-net-statistics
*>
module bleu::network::sysfs_convert;
import std::collections::maybe, bleu::network;

<* `operstate` words. The kernel prints them lowercase (net/core/net-sysfs.c). *>
fn LinkState link_from_operstate(String operstate)
{
	switch (operstate)
	{
		case "up": return UP;
		case "down":
		case "lowerlayerdown": return DOWN;
		case "dormant": return DORMANT;
		default: return UNKNOWN;
	}
}

<*
 `speed` is Mbit/s and -1 (or an unreadable file) when the driver does not know
 it, which is most Wi-Fi drivers and every interface while it is down.
*>
fn Maybe{Mbps} speed_from_sysfs(long mbps)
{
	if (mbps <= 0) return maybe::EMPTY{Mbps};
	return maybe::value((Mbps)mbps);
}

<*
 `carrier` is 1 when the link has carrier. Reading it while the interface is down fails; the caller leaves it empty.
*>
fn Maybe{bool} carrier_from_sysfs(long value) @inline => maybe::value(value != 0);

<* A traffic counter is an unsigned 64-bit count of octets; a negative read is not a counter. *>
fn Maybe{Bytes} counter_from_sysfs(long value)
{
	if (value < 0) return maybe::EMPTY{Bytes};
	return maybe::value((Bytes)value);
}

<*
 Whether `name` may be an interface name used as one path element under
 `/sys/class/net`: not empty, no `/`, and not `.` or `..`. Kernel names never have
 these, so a name that does is refused rather than read through a traversal.
*>
fn bool valid_interface_name(String name)
{
	if (name.len == 0 || name == "." || name == "..") return false;
	foreach (c : name)
	{
		if (c == '/') return false;
	}
	return true;
}