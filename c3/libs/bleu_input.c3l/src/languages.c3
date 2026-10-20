<*
 The xkb layouts this library names, with their BCP-47 language tags and English descriptions.

 Language tags: IANA Language Subtag Registry (https://www.iana.org/assignments/language-subtag-registry),
 which lists every subtag used here (checked 2026-10-20: en, de, fr, es, it, ru, pl, sv, ja, uk, cs and
 the regions US, GB, DE, FR, ES, IT, RU, PL, SE, JP, UA, CZ).

 xkb layout names: the xkeyboard-config layout names (rules/base.lst), e.g. `us`, `de`.

 Descriptions: the English names compositors report (sway and niri report `English (US)`, confirmed in
 sway-ipc(7) examples, 2026-10-20). The other descriptions are UNVERIFIED: the xkeyboard-config file was
 not reachable from this environment. They are used only to match names a compositor reports; a name that
 matches none keeps its own text as its id.

 The table is deliberately short. A layout not listed keeps its xkb name as id, with no language tag.
*>
module bleu::input::languages;

<* One layout the table knows. *>
struct Entry
{
	String xkb;         // xkb layout name, no variant
	String language;    // BCP-47 tag of the language the layout types
	String description; // English layout description (see the module note on verification)
}

const usz TABLE_LENGTH = 12;

const Entry[TABLE_LENGTH] TABLE = {
	{ .xkb = "us", .language = "en-US", .description = "English (US)" },
	{ .xkb = "gb", .language = "en-GB", .description = "English (UK)" },
	{ .xkb = "de", .language = "de-DE", .description = "German" },
	{ .xkb = "fr", .language = "fr-FR", .description = "French" },
	{ .xkb = "es", .language = "es-ES", .description = "Spanish" },
	{ .xkb = "it", .language = "it-IT", .description = "Italian" },
	{ .xkb = "ru", .language = "ru-RU", .description = "Russian" },
	{ .xkb = "pl", .language = "pl-PL", .description = "Polish" },
	{ .xkb = "se", .language = "sv-SE", .description = "Swedish" },
	{ .xkb = "jp", .language = "ja-JP", .description = "Japanese" },
	{ .xkb = "ua", .language = "uk-UA", .description = "Ukrainian" },
	{ .xkb = "cz", .language = "cs-CZ", .description = "Czech" },
};

<* The entry for an xkb layout name without a variant ("de"). NOT_FOUND when the table does not list it. *>
fn Entry? by_xkb(String layout)
{
	foreach (entry : TABLE)
	{
		if (entry.xkb == layout) return entry;
	}
	return NOT_FOUND~;
}

<* The entry whose English description is `description` ("English (US)"). NOT_FOUND when none. *>
fn Entry? by_description(String description)
{
	foreach (entry : TABLE)
	{
		if (entry.description == description) return entry;
	}
	return NOT_FOUND~;
}
