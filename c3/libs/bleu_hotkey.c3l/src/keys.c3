<*
 The platform-neutral keys a shortcut can name: letters, digits, function keys, navigation,
 editing, punctuation and media keys. The names are the ones `chord_text` parses and prints
 (`Ctrl+Alt+T`). Each platform maps a key to its own code in its `keymap_*` file; a key the
 platform has no code for is reported there as UNSUPPORTED, never guessed.
*>
module bleu::hotkey::keys;

<* One key. Ordinals are not stable across versions: store the name, not the number. *>
enum Key : char
{
	A,
	B,
	C,
	D,
	E,
	F,
	G,
	H,
	I,
	J,
	K,
	L,
	M,
	N,
	O,
	P,
	Q,
	R,
	S,
	T,
	U,
	V,
	W,
	X,
	Y,
	Z,
	D0,
	D1,
	D2,
	D3,
	D4,
	D5,
	D6,
	D7,
	D8,
	D9,
	F1,
	F2,
	F3,
	F4,
	F5,
	F6,
	F7,
	F8,
	F9,
	F10,
	F11,
	F12,
	F13,
	F14,
	F15,
	F16,
	F17,
	F18,
	F19,
	F20,
	F21,
	F22,
	F23,
	F24,
	LEFT,
	RIGHT,
	UP,
	DOWN,
	HOME,
	END,
	PAGE_UP,
	PAGE_DOWN,
	INSERT,
	DELETE,
	BACKSPACE,
	TAB,
	RETURN,
	ESCAPE,
	SPACE,
	PRINT_SCREEN,
	PAUSE,
	COMMA,
	PERIOD,
	SLASH,
	SEMICOLON,
	APOSTROPHE,
	LEFT_BRACKET,
	RIGHT_BRACKET,
	BACKSLASH,
	MINUS,
	EQUAL,
	GRAVE,
	MEDIA_PLAY_PAUSE,
	MEDIA_NEXT,
	MEDIA_PREVIOUS,
	MEDIA_STOP,
	VOLUME_UP,
	VOLUME_DOWN,
	VOLUME_MUTE,
}

<* Number of `Key` members. `key_test.c3` checks that it matches the enum. *>
const usz KEY_COUNT = 95;

<*
 The canonical text of a key, as `format_chord` prints it and `parse_chord` accepts it
 (`A`, `0`, `F12`, `PageUp`, `Space`). Unique per key.
*>
fn String Key.name(self)
{
	switch (self)
	{
		case Key.A: return "A";
		case Key.B: return "B";
		case Key.C: return "C";
		case Key.D: return "D";
		case Key.E: return "E";
		case Key.F: return "F";
		case Key.G: return "G";
		case Key.H: return "H";
		case Key.I: return "I";
		case Key.J: return "J";
		case Key.K: return "K";
		case Key.L: return "L";
		case Key.M: return "M";
		case Key.N: return "N";
		case Key.O: return "O";
		case Key.P: return "P";
		case Key.Q: return "Q";
		case Key.R: return "R";
		case Key.S: return "S";
		case Key.T: return "T";
		case Key.U: return "U";
		case Key.V: return "V";
		case Key.W: return "W";
		case Key.X: return "X";
		case Key.Y: return "Y";
		case Key.Z: return "Z";
		case Key.D0: return "0";
		case Key.D1: return "1";
		case Key.D2: return "2";
		case Key.D3: return "3";
		case Key.D4: return "4";
		case Key.D5: return "5";
		case Key.D6: return "6";
		case Key.D7: return "7";
		case Key.D8: return "8";
		case Key.D9: return "9";
		case Key.F1: return "F1";
		case Key.F2: return "F2";
		case Key.F3: return "F3";
		case Key.F4: return "F4";
		case Key.F5: return "F5";
		case Key.F6: return "F6";
		case Key.F7: return "F7";
		case Key.F8: return "F8";
		case Key.F9: return "F9";
		case Key.F10: return "F10";
		case Key.F11: return "F11";
		case Key.F12: return "F12";
		case Key.F13: return "F13";
		case Key.F14: return "F14";
		case Key.F15: return "F15";
		case Key.F16: return "F16";
		case Key.F17: return "F17";
		case Key.F18: return "F18";
		case Key.F19: return "F19";
		case Key.F20: return "F20";
		case Key.F21: return "F21";
		case Key.F22: return "F22";
		case Key.F23: return "F23";
		case Key.F24: return "F24";
		case Key.LEFT: return "Left";
		case Key.RIGHT: return "Right";
		case Key.UP: return "Up";
		case Key.DOWN: return "Down";
		case Key.HOME: return "Home";
		case Key.END: return "End";
		case Key.PAGE_UP: return "PageUp";
		case Key.PAGE_DOWN: return "PageDown";
		case Key.INSERT: return "Insert";
		case Key.DELETE: return "Delete";
		case Key.BACKSPACE: return "Backspace";
		case Key.TAB: return "Tab";
		case Key.RETURN: return "Return";
		case Key.ESCAPE: return "Escape";
		case Key.SPACE: return "Space";
		case Key.PRINT_SCREEN: return "PrintScreen";
		case Key.PAUSE: return "Pause";
		case Key.COMMA: return "Comma";
		case Key.PERIOD: return "Period";
		case Key.SLASH: return "Slash";
		case Key.SEMICOLON: return "Semicolon";
		case Key.APOSTROPHE: return "Apostrophe";
		case Key.LEFT_BRACKET: return "LeftBracket";
		case Key.RIGHT_BRACKET: return "RightBracket";
		case Key.BACKSLASH: return "Backslash";
		case Key.MINUS: return "Minus";
		case Key.EQUAL: return "Equal";
		case Key.GRAVE: return "Grave";
		case Key.MEDIA_PLAY_PAUSE: return "MediaPlayPause";
		case Key.MEDIA_NEXT: return "MediaNext";
		case Key.MEDIA_PREVIOUS: return "MediaPrevious";
		case Key.MEDIA_STOP: return "MediaStop";
		case Key.VOLUME_UP: return "VolumeUp";
		case Key.VOLUME_DOWN: return "VolumeDown";
		case Key.VOLUME_MUTE: return "VolumeMute";
	}
}


<*
 Modifier keys held together with a key. The names follow the shortcuts specification (CTRL,
 ALT, SHIFT, LOGO); `logo` is the Super, Windows or Command key. Each platform maps these bits to
 its own flags (`keymap_*.c3`).
*>
bitstruct Modifiers : uint
{
	bool shift : 0;
	bool ctrl : 1;
	bool alt : 2;
	bool logo : 3;
}