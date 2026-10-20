module bleu::hotkey::chord_test;
import bleu::error, bleu::hotkey, bleu::hotkey::keys;

fn void parses_the_settings_spelling() @test
{
	Chord chord = hotkey::parse_chord("Ctrl+Alt+T")!!;
	assert(chord.mods.ctrl && chord.mods.alt && !chord.mods.shift && !chord.mods.logo);
	assert(chord.key == keys::Key.T);
}

// Modifier names are case-insensitive and the aliases name the same bits.
fn void modifier_names_are_case_insensitive_and_aliased() @test
{
	Chord chord = hotkey::parse_chord("control+OPTION+shift+cmd+f12")!!;
	assert(chord.mods.ctrl && chord.mods.alt && chord.mods.shift && chord.mods.logo);
	assert(chord.key == keys::Key.F12);
	Chord win = hotkey::parse_chord("Win+Space")!!;
	assert(win.mods.logo && win.key == keys::Key.SPACE && !win.mods.ctrl);
}

// A key with no modifiers is a valid chord; a digit name is the digit key.
fn void a_bare_key_and_digits() @test
{
	Chord bare = hotkey::parse_chord("Escape")!!;
	assert(bare.mods.shift == false && bare.key == keys::Key.ESCAPE);
	Chord digit = hotkey::parse_chord("Ctrl+7")!!;
	assert(digit.key == keys::Key.D7);
	Chord alias_name = hotkey::parse_chord("Ctrl+PgDn")!!;
	assert(alias_name.key == keys::Key.PAGE_DOWN);
}

// Each malformed chord is refused as INVALID_ARGUMENT, never parsed into something else.
fn void malformed_chords_are_refused() @test
{
	assert(@catch(hotkey::parse_chord("")) == error::INVALID_ARGUMENT, "empty");
	assert(@catch(hotkey::parse_chord("Ctrl+")) == error::INVALID_ARGUMENT, "trailing plus");
	assert(@catch(hotkey::parse_chord("Ctrl")) == error::INVALID_ARGUMENT, "modifier without a key");
	assert(@catch(hotkey::parse_chord("Ctrl+Ctrl+T")) == error::INVALID_ARGUMENT, "modifier named twice");
	assert(@catch(hotkey::parse_chord("Ctrl+T+Alt")) == error::INVALID_ARGUMENT, "key before the end");
	assert(@catch(hotkey::parse_chord("Ctrl+Bogus")) == error::INVALID_ARGUMENT, "unknown key");
	assert(@catch(hotkey::parse_chord("Hyper+T")) == error::INVALID_ARGUMENT, "unknown modifier");
}

// Formatting and parsing agree: every key of the enum survives a round trip with every modifier set.
fn void every_key_round_trips_through_the_settings_spelling() @test
{
	for (usz i = 0; i < keys::KEY_COUNT; i++)
	{
		keys::Key key = (keys::Key)(char)i;
		Chord chord   = { .mods = { .shift = true, .ctrl = true, .alt = true, .logo = true }, .key = key };
		String text   = hotkey::format_chord(chord, mem);
		defer text.free(mem);
		Chord back = hotkey::parse_chord(text)!!;
		assert(back.key == key, "key survives");
		assert(back.mods.shift && back.mods.ctrl && back.mods.alt && back.mods.logo, "modifiers survive");
	}
}

fn void formats_in_a_fixed_modifier_order() @test
{
	Chord chord = { .mods = { .shift = true, .ctrl = true }, .key = keys::Key.T };
	String text = hotkey::format_chord(chord, mem);
	defer text.free(mem);
	assert(text == "Ctrl+Shift+T");
}

// The portal form: upper-case modifier names and the xkb keysym, as in the shortcuts spec example "CTRL+ALT+Return".
fn void portal_trigger_follows_the_shortcuts_spec() @test
{
	Chord chord    = hotkey::parse_chord("Ctrl+Alt+T")!!;
	String trigger = hotkey::format_portal_trigger(chord, mem);
	defer trigger.free(mem);
	assert(trigger == "CTRL+ALT+t", "modifiers then the keysym");
	Chord ret          = hotkey::parse_chord("Ctrl+Alt+Return")!!;
	String ret_trigger = hotkey::format_portal_trigger(ret, mem);
	defer ret_trigger.free(mem);
	assert(ret_trigger == "CTRL+ALT+Return");
	Chord play          = { .key = keys::Key.MEDIA_PLAY_PAUSE };
	String play_trigger = hotkey::format_portal_trigger(play, mem);
	defer play_trigger.free(mem);
	assert(play_trigger == "XF86AudioPlay");
}