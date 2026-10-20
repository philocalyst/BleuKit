<*
 MCCS (Monitor Control Command Set) feature codes, their kinds and access, and
 the value tables a shell needs (input source, power mode).

 Names and flags are the VESA MCCS 2.2a values as reproduced by ddcutil in
 `src/vcp/vcp_feature_codes.c` (table entries `.v20_name`, `.v20_flags`,
 `.v22_flags`, and the `x60_v2_input_source_values` / `xd6_power_mode_values`
 tables). Where MCCS 3.0 renamed a feature, the 2.x name is used and the
 3.0 name is given in a comment.

 Codes outside this table are still valid to send: every function here takes
 a plain `char`, so vendor-specific codes need no entry.
*>
module bleu::ddc::vcp;

<*
 MCCS feature codes used by Bleu services.

 `constset` rather than `enum` because the codes are sparse (0x10, 0x12, ...).
*>
constset VcpCode : char
{
	// Image: brightness is called "Brightness" in MCCS 2.x and "Luminosity" in 3.0.
	LUMINANCE            = 0x10,
	CONTRAST             = 0x12,
	SELECT_COLOR_PRESET  = 0x14,
	RED_VIDEO_GAIN       = 0x16,
	GREEN_VIDEO_GAIN     = 0x18,
	BLUE_VIDEO_GAIN      = 0x1A,
	// Miscellaneous
	INPUT_SOURCE         = 0x60,
	AUDIO_SPEAKER_VOLUME = 0x62,
	AUDIO_MUTE           = 0x8D,
	POWER_MODE           = 0xD6,
	VCP_VERSION          = 0xDF,
	OSD_LANGUAGE         = 0xCC,
	HORIZONTAL_FREQUENCY = 0xAC,
	VERTICAL_FREQUENCY   = 0xAE,
	FIRMWARE_LEVEL       = 0xC9,
	OSD_BUTTON_CONTROL   = 0xCA,
	DISPLAY_TECHNOLOGY   = 0xB6,
}

<*
 What the value of a feature means.

 - CONTINUOUS: a range from 0 to the reported maximum.
 - NON_CONTINUOUS: a set of discrete values, listed in the capabilities string.
 - TABLE: a byte table read with Table Read (0xE2). No code in this module is a
 table in MCCS 2.x; MCCS 3.0 makes 0x60 a table (ddcutil comment on 0x60).
*>
enum VcpKind : char
{
	CONTINUOUS,
	NON_CONTINUOUS,
	TABLE,
}

<* Whether the host may read, write, or both. *>
enum VcpAccess : char
{
	READ_WRITE,
	READ_ONLY,
	WRITE_ONLY,
}

<*
 One MCCS feature: code, name, kind and access.

 `name` is a static string.
*>
struct VcpFeature
{
	VcpCode code;
	String name;
	VcpKind kind;
	VcpAccess access;
}

const VcpFeature[] FEATURES = {
	{ .code = LUMINANCE, .name = "Luminance", .kind = CONTINUOUS, .access = READ_WRITE },
	{
		.code = CONTRAST,
		.name = "Contrast",
		.kind = CONTINUOUS,
		.access = READ_WRITE
	}, // 2.0 "Select color preset" is SIMPLE_NC; 2.2 and 3.0 are COMPLEX_NC.
	{ .code = SELECT_COLOR_PRESET, .name = "Select color preset", .kind = NON_CONTINUOUS, .access = READ_WRITE },
	{ .code = RED_VIDEO_GAIN, .name = "Video gain: Red", .kind = CONTINUOUS, .access = READ_WRITE },
	{ .code = GREEN_VIDEO_GAIN, .name = "Video gain: Green", .kind = CONTINUOUS, .access = READ_WRITE },
	{
		.code = BLUE_VIDEO_GAIN,
		.name = "Video gain: Blue",
		.kind = CONTINUOUS,
		.access = READ_WRITE
	}, // Quirk: MCCS 2.2a's summary table lists 0x62 as continuous, but its detailed section
	// documents it as non-continuous with reserved values. ddcutil treats it as
	// non-continuous for 2.2 (vcp_feature_codes.c:1729); its 2.0 flags say continuous.
	{ .code = AUDIO_SPEAKER_VOLUME, .name = "Audio speaker volume", .kind = NON_CONTINUOUS, .access = READ_WRITE },
	{ .code = INPUT_SOURCE, .name = "Input source", .kind = NON_CONTINUOUS, .access = READ_WRITE },
	{ .code = AUDIO_MUTE, .name = "Audio mute", .kind = NON_CONTINUOUS, .access = READ_WRITE },
	{ .code = HORIZONTAL_FREQUENCY, .name = "Horizontal frequency", .kind = CONTINUOUS, .access = READ_ONLY },
	{ .code = VERTICAL_FREQUENCY, .name = "Vertical frequency", .kind = CONTINUOUS, .access = READ_ONLY },
	{ .code = DISPLAY_TECHNOLOGY, .name = "Display technology type", .kind = NON_CONTINUOUS, .access = READ_ONLY },
	{ .code = FIRMWARE_LEVEL, .name = "Display firmware level", .kind = NON_CONTINUOUS, .access = READ_ONLY },
	{ .code = OSD_BUTTON_CONTROL, .name = "OSD/Button control", .kind = NON_CONTINUOUS, .access = READ_WRITE },
	{ .code = OSD_LANGUAGE, .name = "OSD language", .kind = NON_CONTINUOUS, .access = READ_WRITE },
	{ .code = POWER_MODE, .name = "Power mode", .kind = NON_CONTINUOUS, .access = READ_WRITE },
	{ .code = VCP_VERSION, .name = "VCP version", .kind = NON_CONTINUOUS, .access = READ_ONLY },
};

<*
 The feature with `code`, or `NOT_FOUND` for a code this table does not know.
 Unknown codes are not errors on the wire; they are simply not documented here.
*>
fn VcpFeature? feature(VcpCode code)
{
	foreach (&f : FEATURES)
	{
		if (f.code == code) return *f;
	}
	return NOT_FOUND~;
}

<*
 Input source values (VCP 0x60), MCCS 2.2a.

 Values 0x01-0x0E are the MCCS 2.0 set. 0x0F-0x12 were added in 2.2 and are
 assumed valid for 2.1 as well (ddcutil `x60_v2_input_source_values`). A value
 that is not listed here is legal and means "a source this table does not name".
*>
constset InputSource : char
{
	VGA_1         = 0x01,
	VGA_2         = 0x02,
	DVI_1         = 0x03,
	DVI_2         = 0x04,
	COMPOSITE_1   = 0x05,
	COMPOSITE_2   = 0x06,
	S_VIDEO_1     = 0x07,
	S_VIDEO_2     = 0x08,
	TUNER_1       = 0x09,
	TUNER_2       = 0x0A,
	TUNER_3       = 0x0B,
	COMPONENT_1   = 0x0C,
	COMPONENT_2   = 0x0D,
	COMPONENT_3   = 0x0E,
	DISPLAYPORT_1 = 0x0F,
	DISPLAYPORT_2 = 0x10,
	HDMI_1        = 0x11,
	HDMI_2        = 0x12,
}

<*
 Power mode values (VCP 0xD6), MCCS 2.2a (ddcutil `xd6_power_mode_values`).

 OFF_HARD (0x05) is documented as write-only ("Write only value to turn off
 display"), so it is never a valid reading. The other values are the DPM/DPMS
 states that the monitor reports.
*>
constset PowerMode : char
{
	ON       = 0x01,
	STANDBY  = 0x02,
	SUSPEND  = 0x03,
	OFF_SOFT = 0x04,
	OFF_HARD = 0x05,
}

<* Human-readable name of an input source value, or `NOT_FOUND` if unlisted. *>
fn String? input_source_name(char value)
{
	switch ((InputSource)value)
	{
		case InputSource.VGA_1: return "VGA-1";
		case InputSource.VGA_2: return "VGA-2";
		case InputSource.DVI_1: return "DVI-1";
		case InputSource.DVI_2: return "DVI-2";
		case InputSource.COMPOSITE_1: return "Composite video 1";
		case InputSource.COMPOSITE_2: return "Composite video 2";
		case InputSource.S_VIDEO_1: return "S-Video-1";
		case InputSource.S_VIDEO_2: return "S-Video-2";
		case InputSource.TUNER_1: return "Tuner-1";
		case InputSource.TUNER_2: return "Tuner-2";
		case InputSource.TUNER_3: return "Tuner-3";
		case InputSource.COMPONENT_1: return "Component video 1";
		case InputSource.COMPONENT_2: return "Component video 2";
		case InputSource.COMPONENT_3: return "Component video 3";
		case InputSource.DISPLAYPORT_1: return "DisplayPort-1";
		case InputSource.DISPLAYPORT_2: return "DisplayPort-2";
		case InputSource.HDMI_1: return "HDMI-1";
		case InputSource.HDMI_2: return "HDMI-2";
		default: return NOT_FOUND~;
	}
}

<* Human-readable name of a power mode value, or `NOT_FOUND` if unlisted. *>
fn String? power_mode_name(char value)
{
	switch ((PowerMode)value)
	{
		case PowerMode.ON: return "DPM: On, DPMS: Off";
		case PowerMode.STANDBY: return "DPM: Off, DPMS: Standby";
		case PowerMode.SUSPEND: return "DPM: Off, DPMS: Suspend";
		case PowerMode.OFF_SOFT: return "DPM: Off, DPMS: Off";
		case PowerMode.OFF_HARD: return "Write only value to turn off display";
		default: return NOT_FOUND~;
	}
}