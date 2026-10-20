<*
 The XKB keysym identifier of each key, for the portal`s `preferred_trigger` strings. The shortcuts
 specification (specifications.freedesktop.org/shortcuts/latest/) takes identifiers from
 xkbcommon-keysyms.h without the XKB_KEY_ prefix, e.g. "CTRL+ALT+Return". Each name below is the
 suffix of an XKB_KEY_* macro in that header (checked: a, 0, F24, Left, Page_Up, BackSpace, space,
 apostrophe, bracketleft, XF86AudioPlay, XF86AudioRaiseVolume, ...). Pure table.
*>
module bleu::hotkey::keymap_xkb;
import bleu::hotkey::keys;

fn String xkb_keysym(keys::Key key)
{
	switch (key)
	{
		case keys::Key.A: return "a";
		case keys::Key.B: return "b";
		case keys::Key.C: return "c";
		case keys::Key.D: return "d";
		case keys::Key.E: return "e";
		case keys::Key.F: return "f";
		case keys::Key.G: return "g";
		case keys::Key.H: return "h";
		case keys::Key.I: return "i";
		case keys::Key.J: return "j";
		case keys::Key.K: return "k";
		case keys::Key.L: return "l";
		case keys::Key.M: return "m";
		case keys::Key.N: return "n";
		case keys::Key.O: return "o";
		case keys::Key.P: return "p";
		case keys::Key.Q: return "q";
		case keys::Key.R: return "r";
		case keys::Key.S: return "s";
		case keys::Key.T: return "t";
		case keys::Key.U: return "u";
		case keys::Key.V: return "v";
		case keys::Key.W: return "w";
		case keys::Key.X: return "x";
		case keys::Key.Y: return "y";
		case keys::Key.Z: return "z";
		case keys::Key.D0: return "0";
		case keys::Key.D1: return "1";
		case keys::Key.D2: return "2";
		case keys::Key.D3: return "3";
		case keys::Key.D4: return "4";
		case keys::Key.D5: return "5";
		case keys::Key.D6: return "6";
		case keys::Key.D7: return "7";
		case keys::Key.D8: return "8";
		case keys::Key.D9: return "9";
		case keys::Key.F1: return "F1";
		case keys::Key.F2: return "F2";
		case keys::Key.F3: return "F3";
		case keys::Key.F4: return "F4";
		case keys::Key.F5: return "F5";
		case keys::Key.F6: return "F6";
		case keys::Key.F7: return "F7";
		case keys::Key.F8: return "F8";
		case keys::Key.F9: return "F9";
		case keys::Key.F10: return "F10";
		case keys::Key.F11: return "F11";
		case keys::Key.F12: return "F12";
		case keys::Key.F13: return "F13";
		case keys::Key.F14: return "F14";
		case keys::Key.F15: return "F15";
		case keys::Key.F16: return "F16";
		case keys::Key.F17: return "F17";
		case keys::Key.F18: return "F18";
		case keys::Key.F19: return "F19";
		case keys::Key.F20: return "F20";
		case keys::Key.F21: return "F21";
		case keys::Key.F22: return "F22";
		case keys::Key.F23: return "F23";
		case keys::Key.F24: return "F24";
		case keys::Key.LEFT: return "Left";
		case keys::Key.RIGHT: return "Right";
		case keys::Key.UP: return "Up";
		case keys::Key.DOWN: return "Down";
		case keys::Key.HOME: return "Home";
		case keys::Key.END: return "End";
		case keys::Key.PAGE_UP: return "Page_Up";
		case keys::Key.PAGE_DOWN: return "Page_Down";
		case keys::Key.INSERT: return "Insert";
		case keys::Key.DELETE: return "Delete";
		case keys::Key.BACKSPACE: return "BackSpace";
		case keys::Key.TAB: return "Tab";
		case keys::Key.RETURN: return "Return";
		case keys::Key.ESCAPE: return "Escape";
		case keys::Key.SPACE: return "space";
		case keys::Key.PRINT_SCREEN: return "Print";
		case keys::Key.PAUSE: return "Pause";
		case keys::Key.COMMA: return "comma";
		case keys::Key.PERIOD: return "period";
		case keys::Key.SLASH: return "slash";
		case keys::Key.SEMICOLON: return "semicolon";
		case keys::Key.APOSTROPHE: return "apostrophe";
		case keys::Key.LEFT_BRACKET: return "bracketleft";
		case keys::Key.RIGHT_BRACKET: return "bracketright";
		case keys::Key.BACKSLASH: return "backslash";
		case keys::Key.MINUS: return "minus";
		case keys::Key.EQUAL: return "equal";
		case keys::Key.GRAVE: return "grave";
		case keys::Key.MEDIA_PLAY_PAUSE: return "XF86AudioPlay";
		case keys::Key.MEDIA_NEXT: return "XF86AudioNext";
		case keys::Key.MEDIA_PREVIOUS: return "XF86AudioPrev";
		case keys::Key.MEDIA_STOP: return "XF86AudioStop";
		case keys::Key.VOLUME_UP: return "XF86AudioRaiseVolume";
		case keys::Key.VOLUME_DOWN: return "XF86AudioLowerVolume";
		case keys::Key.VOLUME_MUTE: return "XF86AudioMute";
	}
}