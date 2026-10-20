<*
 The body markup of the freedesktop notification spec, reduced to plain runs.

 The spec allows `<b>`, `<i>`, `<u>`, `<a href="...">` and `<img src alt>` in the
 body. Everything else is removed: an unknown tag disappears and its text stays,
 an `<img>` contributes its `alt` text (images are not drawn in the centre), and
 the entities `&amp; &lt; &gt; &quot; &apos;` are decoded. A `<` that does not
 begin a tag is text. Unclosed tags end with the body; stray closing tags are
 ignored. The output never holds more than `notify::MAX_SPANS` runs; the rest is dropped.
*>
module bleu::notify::markup;
import std::collections::list, bleu::notify::text;
import bleu::notify;

// Deepest nesting of styling tags that is tracked. Deeper opening tags are ignored with their text kept.
const usz MAX_DEPTH = 16;

// What an open tag does to the style of the text inside it.
enum Tag : char
{
	BOLD,
	ITALIC,
	UNDERLINE,
	LINK,
}

<* Parser state for one body. Strings in `hrefs` and `input` are slices of the body. *>
struct Parser
{
	Allocator allocator;
	String input;
	usz pos;
	DString pending;
	List{notify::Span} spans;
	Tag[MAX_DEPTH] stack;
	String[MAX_DEPTH] hrefs;
	usz depth;
	bool full;
}

<*
 Sanitise a notification body into styled runs. Allocates the runs and their
 text from `allocator`. Never fails: malformed markup degrades to text.

 @param allocator : "Allocator for the runs and their text"
 @param body : "The body as the application sent it (valid UTF-8)"
*>
fn notify::Span[] parse(Allocator allocator, String body)
{
	Parser p;
	p.init(allocator, text::truncate(body, notify::MAX_BODY));
	defer p.free();
	while (p.pos < p.input.len && !p.full)
	{
		if (p.input[p.pos] == '<' && try_tag(&p)) continue;
		usz used = entity_at(p.input, p.pos, &p.pending);
		if (used == 0)
		{
			p.pending.append_char(p.input[p.pos]);
			used = 1;
		}
		p.pos += used;
	}
	p.flush();
	return p.spans.to_aligned_array(allocator);
}

fn void Parser.init(&self, Allocator allocator, String input)
{
	*self = { .allocator = allocator, .input = input };
	self.pending.init(allocator);
	self.spans.init(allocator);
}

fn void Parser.free(&self)
{
	self.pending.free();
	self.spans.free();
}

// Emit the pending text as one run with the style in force now. Empty text emits nothing.
fn void Parser.flush(&self)
{
	if (self.pending.len() == 0 || self.full) return;
	bool bold, italic, underline;
	String link = "";
	for (usz k = 0; k < self.depth; k++)
	{
		switch (self.stack[k])
		{
			case BOLD: bold = true;
			case ITALIC: italic = true;
			case UNDERLINE: underline = true;
			case LINK: link = self.hrefs[k];
		}
	}
	self.spans.push({
		.text = self.pending.str_view().copy(self.allocator),
		.bold = bold,
		.italic = italic,
		.underline = underline,
		.link = link.len == 0 ? link : link.copy(self.allocator),
	});
	self.pending.clear();
	if ((usz)self.spans.len() >= notify::MAX_SPANS) self.full = true;
}

// Try to read a tag at the current position. Returns false when the `<` is plain text.
fn bool try_tag(Parser* p)
{
	String input = p.input;
	usz start = p.pos + 1;
	usz close = start;
	while (close < input.len && input[close] != '>') close++;
	if (close >= input.len) return false;
	String inner = input[start:close - start];
	bool closing = inner.len > 0 && inner[0] == '/';
	usz name_at = closing ? 1 : 0;
	usz name_end = name_at;
	while (name_end < inner.len && is_letter(inner[name_end])) name_end++;
	if (name_end == name_at) return false;
	String name = inner[name_at:name_end - name_at];
	p.pos = close + 1;
	if (name_is(name, "b")) return apply_style(p, closing, BOLD);
	if (name_is(name, "i")) return apply_style(p, closing, ITALIC);
	if (name_is(name, "u")) return apply_style(p, closing, UNDERLINE);
	if (name_is(name, "a"))
	{
		if (closing) return pop_kind(p, LINK);
		String href = "";
		if (try value = attribute(inner, "href")) href = value;
		return push_link(p, href);
	}
	if (name_is(name, "img") && !closing)
	{
		if (try alt = attribute(inner, "alt")) {
			usz at = 0;
			while (at < alt.len)
			{
				usz used = entity_at(alt, at, &p.pending);
				if (used == 0)
				{
					p.pending.append_char(alt[at]);
					used = 1;
				}
				at += used;
			}
		}
	}
	// Unknown tags are removed with their text kept.
	return true;
}

fn bool apply_style(Parser* p, bool closing, Tag kind)
{
	return closing ? pop_kind(p, kind) : push_kind(p, kind, "");
}

fn bool push_link(Parser* p, String href)
{
	if (href.len > notify::MAX_LINK || has_control(href)) href = "";
	return push_kind(p, LINK, href);
}

fn bool push_kind(Parser* p, Tag kind, String href)
{
	p.flush();
	if (p.depth == MAX_DEPTH) return true;
	p.stack[p.depth] = kind;
	p.hrefs[p.depth] = href;
	p.depth++;
	return true;
}

// Close the innermost open tag of `kind`; a closing tag with nothing open to close is ignored.
fn bool pop_kind(Parser* p, Tag kind)
{
	for (usz k = p.depth; k > 0; k--)
	{
		if (p.stack[k - 1] != kind) continue;
		p.flush();
		for (usz j = k - 1; j + 1 < p.depth; j++)
		{
			p.stack[j] = p.stack[j + 1];
			p.hrefs[j] = p.hrefs[j + 1];
		}
		p.depth--;
		return true;
	}
	return true;
}

<*
 The character an entity at `at` stands for, appended to `out`; returns how many
 bytes it used, or 0 when there is no entity at `at`.
*>
fn usz entity_at(String s, usz at, DString* out)
{
	if (s[at] != '&') return 0;
	String rest = s[at:s.len - at];
	foreach (entity : ENTITIES)
	{
		if (rest.len < entity.name.len) continue;
		if (rest[0:entity.name.len] != entity.name) continue;
		out.append_char(entity.value);
		return entity.name.len;
	}
	return 0;
}

struct Entity
{
	String name;
	char value;
}

const Entity[5] ENTITIES = {
	{ "&amp;", '&' },
	{ "&lt;", '<' },
	{ "&gt;", '>' },
	{ "&quot;", '"' },
	{ "&apos;", '\'' },
};

// The value of attribute `name` in the inside of a tag, without its quotes.
fn String? attribute(String inner, String name)
{
	for (usz i = 0; i + name.len < inner.len; i++)
	{
		if (i > 0 && !is_space(inner[i - 1])) continue;
		if (!name_is(inner[i:name.len], name)) continue;
		usz at = i + name.len;
		while (at < inner.len && is_space(inner[at])) at++;
		if (at >= inner.len || inner[at] != '=') continue;
		at++;
		while (at < inner.len && is_space(inner[at])) at++;
		if (at >= inner.len) return NOT_FOUND~;
		char quote = inner[at];
		if (quote != '"' && quote != '\'') return NOT_FOUND~;
		usz end = at + 1;
		while (end < inner.len && inner[end] != quote) end++;
		if (end >= inner.len) return NOT_FOUND~;
		return inner[at + 1:end - at - 1];
	}
	return NOT_FOUND~;
}

fn bool is_letter(char c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');

fn bool is_space(char c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';

fn bool has_control(String s)
{
	foreach (c : s) if (c < ' ' || c == 0x7f) return true;
	return false;
}

// ASCII case-insensitive comparison of a tag or attribute name.
fn bool name_is(String name, String want)
{
	if (name.len != want.len) return false;
	for (usz k = 0; k < name.len; k++)
	{
		char a = name[k];
		if (a >= 'A' && a <= 'Z') a += 'a' - 'A';
		if (a != want[k]) return false;
	}
	return true;
}
