<*
 The Windows virtual-key code of each key (`VK_*` in winuser.h, MinGW-w64 header mirror, lines for
 VK_LEFT 0x25 .. VK_F24 0x87, VK_OEM_1 0xBA .. VK_OEM_7 0xDE). Letters and digits use their ASCII
 values, as winuser.h documents. VK_OEM_* keys are layout-dependent: on a non-US layout the key that
 carries the comma is a different key; the code names the position of the US key. Cross-checked with the
 Microsoft "Virtual-Key Codes" page (learn.microsoft.com/windows/win32/inputdev/virtual-key-codes).
 Pure table: no Windows call is made here.
*>
module bleu::hotkey::keymap_windows;
import bleu::hotkey::keys;

fn uint windows_virtual_key(keys::Key key)
{
	switch (key)
	{
		case keys::Key.A: return 0x41;
		case keys::Key.B: return 0x42;
		case keys::Key.C: return 0x43;
		case keys::Key.D: return 0x44;
		case keys::Key.E: return 0x45;
		case keys::Key.F: return 0x46;
		case keys::Key.G: return 0x47;
		case keys::Key.H: return 0x48;
		case keys::Key.I: return 0x49;
		case keys::Key.J: return 0x4A;
		case keys::Key.K: return 0x4B;
		case keys::Key.L: return 0x4C;
		case keys::Key.M: return 0x4D;
		case keys::Key.N: return 0x4E;
		case keys::Key.O: return 0x4F;
		case keys::Key.P: return 0x50;
		case keys::Key.Q: return 0x51;
		case keys::Key.R: return 0x52;
		case keys::Key.S: return 0x53;
		case keys::Key.T: return 0x54;
		case keys::Key.U: return 0x55;
		case keys::Key.V: return 0x56;
		case keys::Key.W: return 0x57;
		case keys::Key.X: return 0x58;
		case keys::Key.Y: return 0x59;
		case keys::Key.Z: return 0x5A;
		case keys::Key.D0: return 0x30;
		case keys::Key.D1: return 0x31;
		case keys::Key.D2: return 0x32;
		case keys::Key.D3: return 0x33;
		case keys::Key.D4: return 0x34;
		case keys::Key.D5: return 0x35;
		case keys::Key.D6: return 0x36;
		case keys::Key.D7: return 0x37;
		case keys::Key.D8: return 0x38;
		case keys::Key.D9: return 0x39;
		case keys::Key.F1: return 0x70;
		case keys::Key.F2: return 0x71;
		case keys::Key.F3: return 0x72;
		case keys::Key.F4: return 0x73;
		case keys::Key.F5: return 0x74;
		case keys::Key.F6: return 0x75;
		case keys::Key.F7: return 0x76;
		case keys::Key.F8: return 0x77;
		case keys::Key.F9: return 0x78;
		case keys::Key.F10: return 0x79;
		case keys::Key.F11: return 0x7A;
		case keys::Key.F12: return 0x7B;
		case keys::Key.F13: return 0x7C;
		case keys::Key.F14: return 0x7D;
		case keys::Key.F15: return 0x7E;
		case keys::Key.F16: return 0x7F;
		case keys::Key.F17: return 0x80;
		case keys::Key.F18: return 0x81;
		case keys::Key.F19: return 0x82;
		case keys::Key.F20: return 0x83;
		case keys::Key.F21: return 0x84;
		case keys::Key.F22: return 0x85;
		case keys::Key.F23: return 0x86;
		case keys::Key.F24: return 0x87;
		case keys::Key.LEFT: return 0x25;
		case keys::Key.RIGHT: return 0x27;
		case keys::Key.UP: return 0x26;
		case keys::Key.DOWN: return 0x28;
		case keys::Key.HOME: return 0x24;
		case keys::Key.END: return 0x23;
		case keys::Key.PAGE_UP: return 0x21;
		case keys::Key.PAGE_DOWN: return 0x22;
		case keys::Key.INSERT: return 0x2D;
		case keys::Key.DELETE: return 0x2E;
		case keys::Key.BACKSPACE: return 0x08;
		case keys::Key.TAB: return 0x09;
		case keys::Key.RETURN: return 0x0D;
		case keys::Key.ESCAPE: return 0x1B;
		case keys::Key.SPACE: return 0x20;
		case keys::Key.PRINT_SCREEN: return 0x2C;
		case keys::Key.PAUSE: return 0x13;
		case keys::Key.COMMA: return 0xBC;
		case keys::Key.PERIOD: return 0xBE;
		case keys::Key.SLASH: return 0xBF;
		case keys::Key.SEMICOLON: return 0xBA;
		case keys::Key.APOSTROPHE: return 0xDE;
		case keys::Key.LEFT_BRACKET: return 0xDB;
		case keys::Key.RIGHT_BRACKET: return 0xDD;
		case keys::Key.BACKSLASH: return 0xDC;
		case keys::Key.MINUS: return 0xBD;
		case keys::Key.EQUAL: return 0xBB;
		case keys::Key.GRAVE: return 0xC0;
		case keys::Key.MEDIA_PLAY_PAUSE: return 0xB3;
		case keys::Key.MEDIA_NEXT: return 0xB0;
		case keys::Key.MEDIA_PREVIOUS: return 0xB1;
		case keys::Key.MEDIA_STOP: return 0xB2;
		case keys::Key.VOLUME_UP: return 0xAF;
		case keys::Key.VOLUME_DOWN: return 0xAE;
		case keys::Key.VOLUME_MUTE: return 0xAD;
	}
}

<*
 The RegisterHotKey modifier flags of `mods` (winuser.h: MOD_ALT 0x0001, MOD_CONTROL 0x0002,
 MOD_SHIFT 0x0004, MOD_WIN 0x0008; read in the MinGW-w64 header mirror and on the RegisterHotKey page).
 MOD_NOREPEAT is added by the backend, not here.
*>
fn uint windows_modifiers(keys::Modifiers mods)
{
	uint bits = 0;
	if (mods.alt) bits |= 0x0001;
	if (mods.ctrl) bits |= 0x0002;
	if (mods.shift) bits |= 0x0004;
	if (mods.logo) bits |= 0x0008;
	return bits;
}
