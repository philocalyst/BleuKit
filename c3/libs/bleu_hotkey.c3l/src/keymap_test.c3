module bleu::hotkey::keymap_test;
import bleu::error, bleu::hotkey::keys, bleu::hotkey::keymap_windows, bleu::hotkey::keymap_macos, bleu::hotkey::keymap_xkb;

// The enum and its constant agree: the last member is the last ordinal.
fn void key_count_matches_the_enum() @test
{
	assert(keys::Key.VOLUME_MUTE.ordinal + 1 == keys::KEY_COUNT);
}

// Each key has a distinct canonical name, so the settings spelling is unambiguous.
fn void canonical_names_are_unique() @test
{
	for (usz i = 0; i < keys::KEY_COUNT; i++)
	{
		keys::Key a = (keys::Key)(char)i;
		assert(a.name().len > 0);
		for (usz j = i + 1; j < keys::KEY_COUNT; j++)
		{
			keys::Key b = (keys::Key)(char)j;
			assert(a.name() != b.name(), "names are unique");
		}
	}
}

// Windows: every key has a virtual-key code. Values from winuser.h (VK_F1 0x70, VK_LEFT 0x25, VK_OEM_1 0xBA).
fn void windows_codes_match_winuser_h() @test
{
	assert(keymap_windows::windows_virtual_key(keys::Key.A) == 0x41);
	assert(keymap_windows::windows_virtual_key(keys::Key.D0) == 0x30);
	assert(keymap_windows::windows_virtual_key(keys::Key.F1) == 0x70);
	assert(keymap_windows::windows_virtual_key(keys::Key.F24) == 0x87);
	assert(keymap_windows::windows_virtual_key(keys::Key.LEFT) == 0x25);
	assert(keymap_windows::windows_virtual_key(keys::Key.SEMICOLON) == 0xBA);
	assert(keymap_windows::windows_virtual_key(keys::Key.VOLUME_UP) == 0xAF);
}

// macOS: kVK_ANSI_* position codes from HIToolbox Events.h; the media keys have none.
fn void macos_codes_match_events_h() @test
{
	assert(keymap_macos::macos_keycode(keys::Key.T)!! == 0x11);
	assert(keymap_macos::macos_keycode(keys::Key.A)!! == 0x00);
	assert(keymap_macos::macos_keycode(keys::Key.F13)!! == 0x69);
	assert(keymap_macos::macos_keycode(keys::Key.LEFT)!! == 0x7B);
	assert(@catch(keymap_macos::macos_keycode(keys::Key.F21)) == error::UNSUPPORTED);
	assert(@catch(keymap_macos::macos_keycode(keys::Key.MEDIA_NEXT)) == error::UNSUPPORTED);
	assert(@catch(keymap_macos::macos_keycode(keys::Key.INSERT)) == error::UNSUPPORTED);
}

// The keysym names of the portal's trigger strings (xkbcommon-keysyms.h, without the XKB_KEY_ prefix).
fn void keysym_names_match_xkbcommon() @test
{
	assert(keymap_xkb::xkb_keysym(keys::Key.A) == "a");
	assert(keymap_xkb::xkb_keysym(keys::Key.RETURN) == "Return");
	assert(keymap_xkb::xkb_keysym(keys::Key.SPACE) == "space");
	assert(keymap_xkb::xkb_keysym(keys::Key.PAGE_UP) == "Page_Up");
	assert(keymap_xkb::xkb_keysym(keys::Key.BACKSPACE) == "BackSpace");
	assert(keymap_xkb::xkb_keysym(keys::Key.VOLUME_DOWN) == "XF86AudioLowerVolume");
}
