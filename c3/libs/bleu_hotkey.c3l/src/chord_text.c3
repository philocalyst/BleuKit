<*
 Text forms of a chord.

 `format_chord` and `parse_chord` use the spelling people write in settings: "Ctrl+Alt+T".
 `format_portal_trigger` writes the form the portal takes as `preferred_trigger`, defined by the
 shortcuts specification (https://specifications.freedesktop.org/shortcuts/latest/): the modifiers
 CTRL, ALT, SHIFT, LOGO, then the XKB keysym identifier, all joined with "+" ("CTRL+ALT+t").
*>
module bleu::hotkey;
import std::collections::maybe, bleu::error, bleu::hotkey::keys, bleu::hotkey::keymap_xkb;

<* A key name that is not the `Key.name()` spelling, accepted by `parse_chord`. *>
struct KeyAlias
{
	String name;
	keys::Key key;
}

const KeyAlias[6] KEY_ALIASES = {
	{ "Esc", keys::Key.ESCAPE },
	{ "Enter", keys::Key.RETURN },
	{ "PgUp", keys::Key.PAGE_UP },
	{ "PgDn", keys::Key.PAGE_DOWN },
	{ "Del", keys::Key.DELETE },
	{ "Ins", keys::Key.INSERT },
};

<*
 Parse "Ctrl+Alt+T". Names are case-insensitive: Ctrl or Control; Alt or Option; Shift; Super,
 Win, Meta, Cmd or Command (all mean the LOGO key). Exactly one key name, last. A key name is
 `Key.name()` or one of `KEY_ALIASES`.

 @param text : "The chord, for example \"Ctrl+Alt+T\""
 @return? error::INVALID_ARGUMENT : "Empty part, unknown name, a modifier named twice, or no key"
*>
fn Chord? parse_chord(String text)
{
	uint mod_bits  = 0;
	keys::Key key;
	bool have_key  = false;
	Splitter parts = text.tokenize("+");
	while (try raw = parts.next())
	{
		String part = raw.trim();
		if (part.len == 0 || have_key) return error::INVALID_ARGUMENT~;
		if (try bit = modifier_named(part))
		{
			if ((mod_bits & (uint)bit) != 0) return error::INVALID_ARGUMENT~;
			mod_bits |= (uint)bit;
			continue;
		}
		key = key_named(part)!;
		have_key = true;
	}
	if (!have_key) return error::INVALID_ARGUMENT~;
	return { .mods = (Modifiers)mod_bits, .key = key };
}

const uint BIT_SHIFT = 1 << 0; // Modifiers.shift
const uint BIT_CTRL  = 1 << 1; // Modifiers.ctrl
const uint BIT_ALT   = 1 << 2; // Modifiers.alt
const uint BIT_LOGO  = 1 << 3; // Modifiers.logo

<* The modifier bit (a `Modifiers` bit pattern) a name stands for, when it is a modifier name. *>
fn uint? modifier_named(String name)
{
	if (same(name, "Ctrl") || same(name, "Control")) return BIT_CTRL;
	if (same(name, "Alt") || same(name, "Option")) return BIT_ALT;
	if (same(name, "Shift")) return BIT_SHIFT;
	if (same(name, "Super") || same(name, "Win") || same(name, "Meta") || same(name, "Cmd") || same(name, "Command"))
	{
		return BIT_LOGO;
	}
	return error::INVALID_ARGUMENT~;
}

<* The key a name stands for: its canonical `Key.name()` or an alias. *>
fn keys::Key? key_named(String name)
{
	for (usz i = 0; i < keys::KEY_COUNT; i++)
	{
		keys::Key key = (keys::Key)(char)i;
		if (same(key.name(), name)) return key;
	}
	foreach (entry : KEY_ALIASES)
	{
		if (same(entry.name, name)) return entry.key;
	}
	return error::INVALID_ARGUMENT~;
}

// ASCII case-insensitive equality of two names.
fn bool same(String a, String b) @inline => a.compare_to_ignore_case(b) == 0;

<*
 Write the chord as people write it: "Ctrl+Alt+Shift+Super+T" (modifiers in that order, then the
 key's canonical name). `parse_chord` reads this back to the same chord.

 @param allocator : "Owns the returned text"
*>
fn String format_chord(Chord chord, Allocator allocator)
{
	@pool()
	{
		DString text;
		text.init(tmem);
		if (chord.mods.ctrl) text.append("Ctrl+");
		if (chord.mods.alt) text.append("Alt+");
		if (chord.mods.shift) text.append("Shift+");
		if (chord.mods.logo) text.append("Super+");
		text.append(chord.key.name());
		return text.str_view().copy(allocator);
	};
}

<*
 Write the chord as the portal's `preferred_trigger`: "CTRL+ALT+SHIFT+LOGO+<xkb keysym>", the
 modifiers in that order. Source: shortcuts specification, "A shortcut is comprised by a set of
 modifiers ... joined by a + sign".

 @param allocator : "Owns the returned text"
*>
fn String format_portal_trigger(Chord chord, Allocator allocator)
{
	@pool()
	{
		DString text;
		text.init(tmem);
		if (chord.mods.ctrl) text.append("CTRL+");
		if (chord.mods.alt) text.append("ALT+");
		if (chord.mods.shift) text.append("SHIFT+");
		if (chord.mods.logo) text.append("LOGO+");
		text.append(keymap_xkb::xkb_keysym(chord.key));
		return text.str_view().copy(allocator);
	};
}