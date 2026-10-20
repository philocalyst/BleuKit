<*
 Layout names as plain text: xkb names with variants, the short indicator of a layout, and the map from
 the names a compositor reports to stable ids. Pure string work; nothing here touches the system.
*>
module bleu::input::names;
import std::core::string, bleu::input, bleu::input::languages;

const usz SHORT_CODE_LENGTH = 3;
const char ASCII_CASE_BIT   = 32; // 'a' - 'A'

<* An xkb name split into its layout and variant. Both are views into the name it was split from. *>
struct XkbName
{
	String layout;
	String variant;
}

<*
 Split an xkb name into layout and variant: "de(nodeadkeys)" gives ("de", "nodeadkeys") and "us" gives
 ("us", ""). A name that does not end in ")" is a layout without a variant.
*>
fn XkbName parse_xkb(String name)
{
	if (name.len == 0 || name[name.len - 1] != ')') return { .layout = name, .variant = "" };
	for (sz i = 0; i < name.len; i++)
	{
		if (name[i] == '(') return { .layout = name[0:i], .variant = name[i + 1:name.len - i - 2] };
	}
	return { .layout = name, .variant = "" };
}

<* The xkb name of a layout and its variant: ("us", "") gives "us", ("de", "nodeadkeys") gives "de(nodeadkeys)". *>
fn String xkb_name(String layout, String variant, Allocator allocator)
{
	if (variant.len == 0) return layout.copy(allocator);
	return string::tformat("%s(%s)", layout, variant).copy(allocator);
}

<*
 A short indicator of up to three letters, in capitals: "de" gives "DE", "ara" gives "ARA", and text
 that starts with a non-letter gives its leading letters only.
*>
fn String short_code_of(String source, Allocator allocator)
{
	char[SHORT_CODE_LENGTH] letters;
	usz count = 0;
	for (sz i = 0; i < source.len && count < SHORT_CODE_LENGTH; i++)
	{
		char c = source[i];
		if (c >= 'a' && c <= 'z') c = (char)(c - ASCII_CASE_BIT);
		if (c < 'A' || c > 'Z') break;
		letters[count++] = c;
	}
	return ((String)letters[0:count]).copy(allocator);
}

<*
 The region subtag of a BCP-47 tag ("US" in "en-US"), or "" when the tag has none. The first subtag is the
 language and is never a region.
*>
fn String region_of(String tag) @private
{
	sz start = 0;
	for (sz i = 0; i <= tag.len; i++)
	{
		if (i < tag.len && tag[i] != '-') continue;
		sz length = i - start;
		if (start > 0 && length == 2) return tag[start:length];
		start = i + 1;
	}
	return "";
}

<*
 The short indicator for a BCP-47 tag: its region ("DE" for "de-DE"), or its language when it has no
 region ("DE" for "de").
*>
fn String short_code_from_tag(String tag, Allocator allocator)
{
	String region = region_of(tag);
	return short_code_of(region.len > 0 ? region : tag, allocator);
}

<*
 The display name of a layout: its description, with the variant in brackets when there is one.
 Built with `tformat`, so the caller holds a `@pool()`.
*>
fn String display_of(String description, String variant, Allocator allocator) @private
{
	if (variant.len == 0) return description.copy(allocator);
	return string::tformat("%s (%s)", description, variant).copy(allocator);
}

<*
 The layout called `layout` with `variant` ("us", "" or "de", "nodeadkeys"). The name, language and
 short code come from the table when it lists the layout; otherwise the name is the xkb name and the
 language is "".

 Callers hold a `@pool()`: the display name is formatted in tmem.
*>
fn Layout layout_from_parts(String layout, String variant, Allocator allocator)
{
	String description = "";
	String language    = "";
	if (try entry = languages::by_xkb(layout))
	{
		description = entry.description;
		language = entry.language;
	}
	String id = xkb_name(layout, variant, allocator);
	return {
		.id = id,
		.name = description.len > 0 ? display_of(description, variant, allocator) : id,
		.short_code = short_code_of(layout, allocator),
		.language = language.copy(allocator),
		.variant = variant.copy(allocator),
	};
}

<*
 The layout an xkb name ("us", "de(nodeadkeys)") denotes. See `layout_from_parts`.
*>
fn Layout layout_from_xkb(String name, Allocator allocator)
{
	XkbName parsed = parse_xkb(name);
	return layout_from_parts(parsed.layout, parsed.variant, allocator);
}

<*
 The layout for a name a compositor reports for it. A table description ("English (US)") gives the table's
 xkb id ("us"); an xkb name is kept as the id. Any other name is its own id, with no language.

 Callers hold a `@pool()`, as for `layout_from_parts`.
*>
fn Layout layout_from_name(String name, Allocator allocator)
{
	if (try entry = languages::by_description(name)) return layout_from_xkb(entry.xkb, allocator);
	XkbName parsed = parse_xkb(name);
	if (try entry = languages::by_xkb(parsed.layout)) return layout_from_xkb(name, allocator);
	return {
		.id = name.copy(allocator),
		.name = name.copy(allocator),
		.short_code = short_code_of(name, allocator),
		.language = "".copy(allocator),
		.variant = "".copy(allocator),
	};
}