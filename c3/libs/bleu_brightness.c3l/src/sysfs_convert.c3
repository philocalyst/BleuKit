<*
 Pure rules for the Linux brightness knobs: which backlight is the panel, which
 LEDs are keyboard backlights, and how a DRM connector names its I2C bus. No I/O,
 so the rules are tested without hardware.

 Sources: Documentation/ABI/testing/sysfs-class-backlight
 (https://docs.kernel.org/admin-guide/abi-testing-files.html), which says to
 prefer `firmware` over `platform` over `raw` when one panel has several
 interfaces; Documentation/leds/leds-class.rst for the `<name>::kbd_backlight`
 naming; and Documentation/gpu/drm-kms.rst for the connector `ddc` link.
*>
module bleu::brightness::sysfs;
import bleu::error;

<*
 How much a backlight `type` is preferred when one panel has several. The kernel
 lists them as `firmware`, `platform`, `raw`; a higher rank wins.
*>
fn int type_rank(String type)
{
	switch (type)
	{
		case "firmware": return 3;
		case "platform": return 2;
		case "raw": return 1;
		default: return 0;
	}
}

<*
 Index of the best candidate: the highest rank, and among equal ranks the name
 that sorts first, so the choice does not depend on directory order.

 @require ranks.len == names.len : "one rank per name"
 @return "The index, or -1 when there are no candidates"
*>
fn sz select_best(int[] ranks, String[] names)
{
	sz best = -1;
	for (sz i = 0; i < ranks.len; i++)
	{
		if (best < 0 || ranks[i] > ranks[best])
		{
			best = i;
		}
		else if (ranks[i] == ranks[best] && names[i].compare_to(names[best]) < 0)
		{
			best = i;
		}
	}
	return best;
}

<* Whether a `/sys/class/leds` entry is a keyboard backlight: `input5::kbd_backlight` or `:kbd_backlight`. *>
fn bool is_keyboard_backlight(String name) => name.ends_with("kbd_backlight");

<*
 Whether a `/sys/class/drm` entry is a connector: `card<N>-<CONNECTOR>`, such as
 `card1-DP-1`. Render nodes (`renderD128`) and bare cards (`card0`) are not.
*>
fn bool is_connector_name(String name)
{
	if (!name.starts_with("card")) return false;
	usz i      = 4;
	usz digits = 0;
	while (i < name.len && name[i] >= '0' && name[i] <= '9')
	{
		i++;
		digits++;
	}
	return digits > 0 && i + 1 < name.len && name[i] == '-';
}

<*
 The I2C adapter number named by a `ddc` link target, such as
 `../../../../bus/i2c/devices/i2c-7`: the last path element must be `i2c-<N>`.

 @return? NOT_FOUND : "The target does not name an I2C adapter"
*>
fn int? bus_from_link(String target)
{
	usz start = 0;
	for (usz i = 0; i < target.len; i++)
	{
		if (target[i] == '/') start = i + 1;
	}
	String leaf = target[start:target.len - start];
	if (!leaf.starts_with("i2c-") || leaf.len == 4) return NOT_FOUND~;
	int bus = 0;
	for (usz i = 4; i < leaf.len; i++)
	{
		char c = leaf[i];
		if (c < '0' || c > '9') return NOT_FOUND~;
		bus = bus * 10 + (int)(c - '0');
	}
	return bus;
}