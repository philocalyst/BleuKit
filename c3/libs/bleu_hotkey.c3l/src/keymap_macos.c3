<*
 The macOS virtual keycode of each key (`kVK_*` in HIToolbox Events.h, MacOSX10.13 SDK header).
 LAYOUT CAVEAT: the kVK_ANSI_* names are key POSITIONS of the ANSI layout. RegisterEventHotKey matches
 the physical key at that position, so on a French or German layout the shortcut for "T" is on the key
 that prints a different letter there. Media, volume, Insert, Print Screen, Pause and F21-F24 have no
 keycode in these headers and are UNSUPPORTED here (media and volume keys arrive as system events,
 not key events). Pure table.
*>
module bleu::hotkey::keymap_macos;
import bleu::hotkey::keys, bleu::error;

fn uint? macos_keycode(keys::Key key)
{
	switch (key)
	{
		case keys::Key.A: return 0x00;
		case keys::Key.B: return 0x0B;
		case keys::Key.C: return 0x08;
		case keys::Key.D: return 0x02;
		case keys::Key.E: return 0x0E;
		case keys::Key.F: return 0x03;
		case keys::Key.G: return 0x05;
		case keys::Key.H: return 0x04;
		case keys::Key.I: return 0x22;
		case keys::Key.J: return 0x26;
		case keys::Key.K: return 0x28;
		case keys::Key.L: return 0x25;
		case keys::Key.M: return 0x2E;
		case keys::Key.N: return 0x2D;
		case keys::Key.O: return 0x1F;
		case keys::Key.P: return 0x23;
		case keys::Key.Q: return 0x0C;
		case keys::Key.R: return 0x0F;
		case keys::Key.S: return 0x01;
		case keys::Key.T: return 0x11;
		case keys::Key.U: return 0x20;
		case keys::Key.V: return 0x09;
		case keys::Key.W: return 0x0D;
		case keys::Key.X: return 0x07;
		case keys::Key.Y: return 0x10;
		case keys::Key.Z: return 0x06;
		case keys::Key.D0: return 0x1D;
		case keys::Key.D1: return 0x12;
		case keys::Key.D2: return 0x13;
		case keys::Key.D3: return 0x14;
		case keys::Key.D4: return 0x15;
		case keys::Key.D5: return 0x17;
		case keys::Key.D6: return 0x16;
		case keys::Key.D7: return 0x1A;
		case keys::Key.D8: return 0x1C;
		case keys::Key.D9: return 0x19;
		case keys::Key.F1: return 0x7A;
		case keys::Key.F2: return 0x78;
		case keys::Key.F3: return 0x63;
		case keys::Key.F4: return 0x76;
		case keys::Key.F5: return 0x60;
		case keys::Key.F6: return 0x61;
		case keys::Key.F7: return 0x62;
		case keys::Key.F8: return 0x64;
		case keys::Key.F9: return 0x65;
		case keys::Key.F10: return 0x6D;
		case keys::Key.F11: return 0x67;
		case keys::Key.F12: return 0x6F;
		case keys::Key.F13: return 0x69;
		case keys::Key.F14: return 0x6B;
		case keys::Key.F15: return 0x71;
		case keys::Key.F16: return 0x6A;
		case keys::Key.F17: return 0x40;
		case keys::Key.F18: return 0x4F;
		case keys::Key.F19: return 0x50;
		case keys::Key.F20: return 0x5A;
		case keys::Key.F21: return error::UNSUPPORTED~;
		case keys::Key.F22: return error::UNSUPPORTED~;
		case keys::Key.F23: return error::UNSUPPORTED~;
		case keys::Key.F24: return error::UNSUPPORTED~;
		case keys::Key.LEFT: return 0x7B;
		case keys::Key.RIGHT: return 0x7C;
		case keys::Key.UP: return 0x7E;
		case keys::Key.DOWN: return 0x7D;
		case keys::Key.HOME: return 0x73;
		case keys::Key.END: return 0x77;
		case keys::Key.PAGE_UP: return 0x74;
		case keys::Key.PAGE_DOWN: return 0x79;
		case keys::Key.INSERT: return error::UNSUPPORTED~;
		case keys::Key.DELETE: return 0x75;
		case keys::Key.BACKSPACE: return 0x33;
		case keys::Key.TAB: return 0x30;
		case keys::Key.RETURN: return 0x24;
		case keys::Key.ESCAPE: return 0x35;
		case keys::Key.SPACE: return 0x31;
		case keys::Key.PRINT_SCREEN: return error::UNSUPPORTED~;
		case keys::Key.PAUSE: return error::UNSUPPORTED~;
		case keys::Key.COMMA: return 0x2B;
		case keys::Key.PERIOD: return 0x2F;
		case keys::Key.SLASH: return 0x2C;
		case keys::Key.SEMICOLON: return 0x29;
		case keys::Key.APOSTROPHE: return 0x27;
		case keys::Key.LEFT_BRACKET: return 0x21;
		case keys::Key.RIGHT_BRACKET: return 0x1E;
		case keys::Key.BACKSLASH: return 0x2A;
		case keys::Key.MINUS: return 0x1B;
		case keys::Key.EQUAL: return 0x18;
		case keys::Key.GRAVE: return 0x32;
		case keys::Key.MEDIA_PLAY_PAUSE: return error::UNSUPPORTED~;
		case keys::Key.MEDIA_NEXT: return error::UNSUPPORTED~;
		case keys::Key.MEDIA_PREVIOUS: return error::UNSUPPORTED~;
		case keys::Key.MEDIA_STOP: return error::UNSUPPORTED~;
		case keys::Key.VOLUME_UP: return error::UNSUPPORTED~;
		case keys::Key.VOLUME_DOWN: return error::UNSUPPORTED~;
		case keys::Key.VOLUME_MUTE: return error::UNSUPPORTED~;
	}
}

<*
 The Carbon modifier bits of RegisterEventHotKey: cmdKey (LOGO), shiftKey, optionKey (ALT) and
 controlKey (CTRL). Bit numbers from HIToolbox Events.h: cmdKeyBit 8, shiftKeyBit 9, optionKeyBit 11,
 controlKeyBit 12 (MacOSX10.13 SDK header, read). Pure table.
*>
fn uint macos_modifiers(keys::Modifiers mods)
{
	uint bits = 0;
	if (mods.logo) bits |= 1 << 8;
	if (mods.shift) bits |= 1 << 9;
	if (mods.alt) bits |= 1 << 11;
	if (mods.ctrl) bits |= 1 << 12;
	return bits;
}