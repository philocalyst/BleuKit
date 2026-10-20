<*
 Reads the kill switches of the Bluetooth radio from sysfs. Only reads: the
 library never writes /dev/rfkill or the sysfs switches, because clearing a
 block is the user's decision. Source: Linux rfkill (Documentation/driver-api/rfkill.rst;
 the sysfs attributes type, soft and hard in /sys/class/rfkill/rfkillN).
*>
module bleu::bluetooth::bluez @feat(LINUX);
import std::io::path, bleu::rt::fs;

const String RFKILL_DIR            = "/sys/class/rfkill";
const String RFKILL_BLUETOOTH_TYPE = "bluetooth";
const sz RFKILL_TEXT_CAPACITY      = 32;

<*
 True when a Bluetooth rfkill switch is set, soft or hard. Missing sysfs
 (a container, or no rfkill subsystem) is no block.
*>
fn bool rfkill_blocked(String root)
{
	@pool()
	{
		String dir = string::tformat("%s%s", root, RFKILL_DIR);
		if (try entries = fs::list_dir(tmem, dir))
		{
			foreach (entry : entries)
			{
				String switch_dir = string::tformat("%s/%s", dir, (String)entry);
				if (rfkill_text(switch_dir, "type") != RFKILL_BLUETOOTH_TYPE) continue;
				if (rfkill_flag(switch_dir, "soft") || rfkill_flag(switch_dir, "hard")) return true;
			}
		}
		return false;
	};
}

// One sysfs attribute as text, or "" when it cannot be read.
fn String rfkill_text(String switch_dir, String attribute) @private
{
	char[RFKILL_TEXT_CAPACITY] buffer;
	String text = fs::read_trimmed(string::tformat("%s/%s", switch_dir, attribute), buffer[..]) ?? "";
	return text;
}

// A sysfs attribute that reads 1 when the switch is set.
fn bool rfkill_flag(String switch_dir, String attribute) @private
{
	return rfkill_text(switch_dir, attribute) == "1";
}