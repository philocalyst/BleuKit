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
				if (!rfkill_is(switch_dir, "type", RFKILL_BLUETOOTH_TYPE)) continue;
				if (rfkill_is(switch_dir, "soft", "1") || rfkill_is(switch_dir, "hard", "1")) return true;
			}
		}
		return false;
	};
}

// True when a sysfs attribute reads exactly `expected`. The text is read into this frame's buffer and
// compared here: a String into that buffer must not outlive the call.
fn bool rfkill_is(String switch_dir, String attribute, String expected) @private
{
	char[RFKILL_TEXT_CAPACITY] buffer;
	String text = fs::read_trimmed(string::tformat("%s/%s", switch_dir, attribute), buffer[..]) ?? "";
	return text == expected;
}