<*
 Pure conversions from what the operating systems report to Bleu's types: the
 class of device and appearance to an icon, the battery percentage, modalias
 text to vendor and product, and profile UUIDs to profiles. No I/O, so every
 platform compiles and tests them the same way.
*>
module bleu::bluetooth;
import std::collections::maybe, bleu::unit;

// Major device class (bits 8-12 of the class of device): Bluetooth Assigned Numbers, Baseband, Class of Device.
const uint MAJOR_COMPUTER = 0x01;
const uint MAJOR_PHONE = 0x02;
const uint MAJOR_AUDIO_VIDEO = 0x04;
const uint MAJOR_PERIPHERAL = 0x05;
const uint MAJOR_IMAGING = 0x06;
const uint MAJOR_WEARABLE = 0x07;

// Minor device class (bits 2-7), as the value of (class >> 2) & 0x3f.
const uint MINOR_AV_WEARABLE_HEADSET = 0x01;
const uint MINOR_AV_HANDSFREE = 0x02;
const uint MINOR_AV_MICROPHONE = 0x04;
const uint MINOR_AV_LOUDSPEAKER = 0x05;
const uint MINOR_AV_HEADPHONES = 0x06;
const uint MINOR_AV_PORTABLE_AUDIO = 0x07;
const uint MINOR_AV_VIDEO_CAMERA = 0x0C;
const uint MINOR_AV_CAMCORDER = 0x0D;
const uint MINOR_PERIPHERAL_JOYSTICK = 0x01;
const uint MINOR_PERIPHERAL_GAMEPAD = 0x02;
const uint MINOR_PERIPHERAL_KEYBOARD_BIT = 0x10;
const uint MINOR_PERIPHERAL_POINTING_BIT = 0x20;
const uint MINOR_IMAGING_DISPLAY_BIT = 0x04;
const uint MINOR_IMAGING_CAMERA_BIT = 0x08;
const uint MINOR_IMAGING_PRINTER_BIT = 0x20;
const uint MINOR_WEARABLE_WRISTWATCH = 0x01;

// Bits of the class of device (24 bits in all).
const uint CLASS_MAJOR_MASK = 0x1F00;
const uint CLASS_MAJOR_SHIFT = 8;
const uint CLASS_MINOR_MASK = 0xFC;
const uint CLASS_MINOR_SHIFT = 2;

// BLE appearance: the category is the high ten bits, the subtype the low six.
const ushort APPEARANCE_CATEGORY_SHIFT = 6;
const ushort APPEARANCE_SUBTYPE_MASK = 0x3F;
const ushort APPEARANCE_CATEGORY_PHONE = 1;
const ushort APPEARANCE_CATEGORY_COMPUTER = 2;
const ushort APPEARANCE_CATEGORY_WATCH = 3;
const ushort APPEARANCE_CATEGORY_DISPLAY = 5;
const ushort APPEARANCE_CATEGORY_HID = 15;
const ushort APPEARANCE_HID_KEYBOARD = 1;
const ushort APPEARANCE_HID_MOUSE = 2;
const ushort APPEARANCE_HID_JOYSTICK = 3;
const ushort APPEARANCE_HID_GAMEPAD = 4;

// Battery percentages are 0 to 100; BlueZ sends 255 (UINT8_MAX) when the level is unknown.
const uint BATTERY_PERCENT_MAX = 100;

// Modalias text: "<source>:v<vendor>p<product>d<version>", each number four hex digits.
const sz MODALIAS_HEX_DIGITS = 4;
// Characters from the ":" of a modalias to the end of its last number: ":v" + three numbers + two letters.
const sz MODALIAS_LENGTH_AFTER_SOURCE = 16;

<*
 The icon for a class of device. Returns UNKNOWN for a class this library does
 not name. Source: Bluetooth Assigned Numbers, Baseband, Class of Device; the
 table was taken from upower's decoder as cited in docs/research/bluetooth.md
 (C18, single source).

 @param class_of_device : "The 24-bit class of device; 0 when unknown"
*>
fn Icon icon_from_class(uint class_of_device)
{
	uint major = (class_of_device & CLASS_MAJOR_MASK) >> CLASS_MAJOR_SHIFT;
	uint minor = (class_of_device & CLASS_MINOR_MASK) >> CLASS_MINOR_SHIFT;
	switch (major)
	{
		case MAJOR_COMPUTER: return COMPUTER;
		case MAJOR_PHONE: return PHONE;
		case MAJOR_AUDIO_VIDEO: return audio_video_icon(minor);
		case MAJOR_PERIPHERAL: return peripheral_icon(minor);
		case MAJOR_IMAGING: return imaging_icon(minor);
		case MAJOR_WEARABLE: return minor == MINOR_WEARABLE_WRISTWATCH ? WATCH : WEARABLE;
		default: return UNKNOWN;
	}
}

fn Icon audio_video_icon(uint minor) @private
{
	switch (minor)
	{
		case MINOR_AV_WEARABLE_HEADSET:
		case MINOR_AV_HANDSFREE: return HEADSET;
		case MINOR_AV_HEADPHONES: return HEADPHONES;
		case MINOR_AV_MICROPHONE: return MICROPHONE;
		case MINOR_AV_LOUDSPEAKER:
		case MINOR_AV_PORTABLE_AUDIO: return LOUDSPEAKER;
		case MINOR_AV_VIDEO_CAMERA:
		case MINOR_AV_CAMCORDER: return CAMERA;
		default: return UNKNOWN;
	}
}

// The keyboard and pointing bits sit above the type bits; a combo device is a keyboard.
fn Icon peripheral_icon(uint minor) @private
{
	if ((minor & MINOR_PERIPHERAL_KEYBOARD_BIT) != 0) return KEYBOARD;
	if ((minor & MINOR_PERIPHERAL_POINTING_BIT) != 0) return MOUSE;
	switch (minor & 0x0F)
	{
		case MINOR_PERIPHERAL_JOYSTICK: return JOYSTICK;
		case MINOR_PERIPHERAL_GAMEPAD: return GAMEPAD;
		default: return UNKNOWN;
	}
}

fn Icon imaging_icon(uint minor) @private
{
	if ((minor & MINOR_IMAGING_PRINTER_BIT) != 0) return PRINTER;
	if ((minor & MINOR_IMAGING_CAMERA_BIT) != 0) return CAMERA;
	if ((minor & MINOR_IMAGING_DISPLAY_BIT) != 0) return DISPLAY;
	return UNKNOWN;
}

<*
 The icon for a BLE appearance value, or UNKNOWN. The categories are the GAP
 appearance values; they were not fetched from the Assigned Numbers
 document (see docs/research/bluetooth_impl.md, "not verified").

 @param appearance : "The 16-bit appearance; 0 when unknown"
*>
fn Icon icon_from_appearance(ushort appearance)
{
	ushort category = appearance >> APPEARANCE_CATEGORY_SHIFT;
	ushort subtype  = appearance & APPEARANCE_SUBTYPE_MASK;
	switch (category)
	{
		case APPEARANCE_CATEGORY_PHONE: return PHONE;
		case APPEARANCE_CATEGORY_COMPUTER: return COMPUTER;
		case APPEARANCE_CATEGORY_WATCH: return WATCH;
		case APPEARANCE_CATEGORY_DISPLAY: return DISPLAY;
		case APPEARANCE_CATEGORY_HID:
			switch (subtype)
			{
				case APPEARANCE_HID_KEYBOARD: return KEYBOARD;
				case APPEARANCE_HID_MOUSE: return MOUSE;
				case APPEARANCE_HID_JOYSTICK: return JOYSTICK;
				case APPEARANCE_HID_GAMEPAD: return GAMEPAD;
				default: return UNKNOWN;
			}
		default: return UNKNOWN;
	}
}

<*
 The icon a device shows: its class of device if that names one, otherwise
 its appearance.
*>
fn Icon icon_of(uint class_of_device, ushort appearance)
{
	Icon by_class = icon_from_class(class_of_device);
	if (by_class != UNKNOWN) return by_class;
	return icon_from_appearance(appearance);
}

<*
 A battery percentage as a level. A value above 100, including BlueZ's 255
 "unknown", is no reading at all.

 @param percent : "The raw 0-100 value from the device"
*>
fn Maybe{Level} battery_level(uint percent)
{
	if (percent > BATTERY_PERCENT_MAX) return { };
	return maybe::value(unit::from_percent((float)percent));
}

<*
 The vendor and product in a modalias such as "usb:v1D6Bp0246d0533" or
 "bluetooth:v004Cp0000d0100". The layout is fixed: a source name, ":v", then
 three four-digit hex numbers separated by "p" and "d". Returns empty for any
 other shape, including a non-hex digit.
*>
fn Maybe{PnpId} parse_modalias(String modalias)
{
	sz colon = modalias.index_of_char(':') ?? 0;
	if (colon == 0 || modalias.len < colon + MODALIAS_LENGTH_AFTER_SOURCE) return { };
	if (modalias[colon + 1] != 'v' || modalias[colon + 6] != 'p' || modalias[colon + 11] != 'd') return { };
	if (try vendor = hex_number(modalias[colon + 2 : MODALIAS_HEX_DIGITS]))
	{
		if (try product = hex_number(modalias[colon + 7 : MODALIAS_HEX_DIGITS]))
		{
			if (try version = hex_number(modalias[colon + 12 : MODALIAS_HEX_DIGITS]))
			{
				return maybe::value(
					(PnpId) { .source = pnp_source(modalias[0 : colon]), .vendor = vendor, .product = product, .version = version }
				);
			}
		}
	}
	return { };
}

fn PnpSource pnp_source(String name) @private
{
	if (name == "bluetooth") return BLUETOOTH;
	if (name == "usb") return USB;
	return OTHER;
}

// The value of one hex digit, or -1 when the character is not one.
fn int hex_digit(char c)
{
	if (c >= '0' && c <= '9') return (int)c - (int)'0';
	if (c >= 'a' && c <= 'f') return (int)c - (int)'a' + 10;
	if (c >= 'A' && c <= 'F') return (int)c - (int)'A' + 10;
	return -1;
}

// Four hex digits, or an excuse when the text is short or not hex.
fn ushort? hex_number(String digits) @private
{
	if (digits.len != MODALIAS_HEX_DIGITS) return NOT_FOUND~;
	uint value = 0;
	foreach (c : digits)
	{
		int nibble = hex_digit(c);
		if (nibble < 0) return NOT_FOUND~;
		value = value * 16 + (uint)nibble;
	}
	return (ushort)value;
}

// Service class UUIDs of the profiles, in the order of `Profile`. Source: Bluetooth Assigned Numbers
// (Service Discovery Protocol service classes; values in docs/research/bluetooth.md C19).
const String[6] PROFILE_UUIDS = {
	"0000110a-0000-1000-8000-00805f9b34fb", // A2DP_SOURCE
	"0000110b-0000-1000-8000-00805f9b34fb", // A2DP_SINK
	"00001108-0000-1000-8000-00805f9b34fb", // HSP_HEADSET
	"00001112-0000-1000-8000-00805f9b34fb", // HSP_GATEWAY
	"0000111e-0000-1000-8000-00805f9b34fb", // HFP_HANDSFREE
	"0000111f-0000-1000-8000-00805f9b34fb", // HFP_GATEWAY
};

<* The UUID text of a profile, in the lower case BlueZ uses. *>
fn String profile_uuid(Profile profile) => PROFILE_UUIDS[profile.ordinal];

<* The profile a UUID names, or an excuse when it is not one this library knows. Compares lower-case text. *>
fn Profile? profile_from_uuid(String uuid)
{
	foreach (i, candidate : PROFILE_UUIDS)
	{
		if (candidate == uuid) return (Profile)i;
	}
	return NOT_FOUND~;
}

// "dev_" before the address, and the address in its 17 characters.
const sz DEVICE_PATH_PREFIX = 4;
const sz ADDRESS_TEXT_LENGTH = 17;

<*
 The device address named by a BlueZ device object path, such as
 "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF" gives "AA:BB:CC:DD:EE:FF".

 @param allocator : "Allocator for the returned address"
 @return? NOT_FOUND : "The path does not end in a device address"
*>
fn String? address_of_device_path(String path, Allocator allocator)
{
	sz tail_len = DEVICE_PATH_PREFIX + ADDRESS_TEXT_LENGTH;
	if (path.len < tail_len) return NOT_FOUND~;
	String tail = path[path.len - tail_len : tail_len];
	if (!tail.starts_with("dev_")) return NOT_FOUND~;
	char[ADDRESS_TEXT_LENGTH] text;
	for (sz i = 0; i < ADDRESS_TEXT_LENGTH; i++)
	{
		char c = tail[DEVICE_PATH_PREFIX + i];
		if (i % 3 == 2)
		{
			if (c != '_') return NOT_FOUND~;
			text[i] = ':';
			continue;
		}
		if (hex_digit(c) < 0) return NOT_FOUND~;
		text[i] = (c >= 'a' && c <= 'f') ? (char)(c - 32) : c;
	}
	return ((String)text[..]).copy(allocator);
}
