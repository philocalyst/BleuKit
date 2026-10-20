<*
 The `Exec=` command line of a desktop entry: quoting, field codes, and the
 expansion into one argument vector per program invocation.

 Source: Desktop Entry Specification 1.5, section "The Exec key" (quoting rules,
 reserved characters, field code table, deprecated and unknown codes).

 Cross-checked against GLib's `expand_application_parameters` and `expand_macro`
 (`gio/gdesktopappinfo.c`, https://github.com/GNOME/glib). They agree on `%%`,
 on `%i` becoming `--icon` and the icon, on `%c` and `%k`, and on deprecated
 codes being dropped. They differ in two places this module follows the
 specification on: GLib drops an unknown code silently (this module refuses the
 command line), and GLib appends `%f` to a command with no file code (this module
 does not). GLib also parses the expanded text with shell rules; this module
 splits the command line before inserting values, so a value is never re-split.

 Input is the Exec value as `DesktopEntry.exec` holds it, that is after the
 general string escapes (`\s \n \t \r \\`) have been decoded. Quoting is undone
 here, then field codes are expanded. The rules, as implemented:

 * Arguments are separated by spaces or tabs. Double quotes group an argument;
 inside them `\"`, `` \` ``, `\$` and `\\` stand for the character after the
 backslash, and `%%` is a literal percent.
 * Outside quotes a backslash is an ordinary character. The specification
 requires reserved characters to be quoted; an unquoted one is passed through
 rather than rejected, as GLib does.
 * `%f`/`%u` take one file or URL per invocation: with N files the command runs
 N times, and with none the code is removed. `%F`/`%U` take all of them in one
 invocation. At most one of the four may appear per command line.
 * `%i` becomes `--icon <icon>`, or nothing when there is no icon. `%c` is the
 translated name and `%k` the desktop file location (empty when unknown).
 * `%i`, `%F` and `%U` must be an argument of their own. A field code inside
 double quotes is refused, because the specification leaves its result
 undefined; the command is not guessed at.
 * Deprecated codes (`%d %D %n %N %v %m`) are removed. Any other code is
 invalid, and the whole command line is refused.
 * A field code's value is inserted once and never expanded again.
*>
module bleu::xdg::exec;
import bleu::error, std::collections::list;

const char QUOTE              = '"';
const char ESCAPE             = '\\';
const char PERCENT            = '%';
const char ARGUMENT_SEPARATOR = ' ';
const char TAB                = '\t';
const String ICON_FLAG        = "--icon";

<*
 Values that the field codes stand for. Lists give one value per file or URL.
*>
struct Context
{
	String[] files; // %f (one per invocation) and %F (all of them)
	String[] urls; // %u (one per invocation) and %U (all of them)
	String icon; // %i, expanded to `--icon` and this, or to nothing when empty
	String name; // %c, the translated Name
	String location; // %k, the desktop file's location, empty when unknown
}

<* A literal run of text, or a field code, inside one argument. *>
struct Part
{
	bool is_field;
	String text; // literal text, when !is_field
	char code; // the field code letter, when is_field
}

<* One argument as written: its parts, and whether any literal text (even an empty quoted one) was written. *>
struct Word
{
	List{Part} parts;
	bool has_literal;
}

<*
 Expand an Exec command line into the argument vectors to run.

 @param [&inout] allocator : "Allocator for the vectors and their strings"
 @param exec : "The decoded Exec value of a desktop entry"
 @return "One argument vector per invocation: usually one, more with %f or %u and several files or URLs"
 @return? error::PROTOCOL : "The command line is empty, has unbalanced quotes, an unknown or misplaced field code, or more than one of %f %u %F %U"
*>
fn String[][]? expand(Allocator allocator, String exec, Context context)
{
	List{Word} words;
	words.tinit();
	tokenize(exec, &words)!;
	validate(words.array_view())!;
	List{String[]} invocations;
	invocations.tinit();
	sz count = invocation_count(words.array_view(), context);
	for (sz index = 0; index < count; index++)
	{
		String[] argv = build_argv(allocator, words.array_view(), context, index);
		if (argv.len == 0) return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			0,
			"the Exec command line names no program"
		)~;
		invocations.push(argv);
	}
	return invocations.to_aligned_array(allocator);
}

// Split `exec` into words, undoing quotes and collecting field codes.
fn void? tokenize(String exec, List{Word}* words) @local
{
	DString text;
	text.init(tmem, exec.len);
	Word word      = new_word();
	bool in_word   = false;
	bool in_quotes = false;
	sz i           = 0;
	while (i < exec.len)
	{
		char c = exec[i];
		if (in_quotes)
		{
			if (c == QUOTE)
			{
				in_quotes = false;
				i++;
			}
			else if (c == ESCAPE && i + 1 < exec.len && is_quotable(exec[i + 1]))
			{
				text.append_char(exec[i + 1]);
				i += 2;
			}
			else if (c == PERCENT && i + 1 < exec.len && exec[i + 1] == PERCENT)
			{
				text.append_char(PERCENT);
				i += 2;
			}
			else if (c == PERCENT)
			{
				return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "field codes may not be quoted")~;
			}
			else
			{
				text.append_char(c);
				i++;
			}
			continue;
		}
		if (c == ARGUMENT_SEPARATOR || c == TAB)
		{
			if (in_word) finish_word(words, &word, &text);
			in_word = false;
			i++;
		}
		else if (c == QUOTE)
		{
			in_quotes = true;
			in_word = true;
			word.has_literal = true;
			i++;
		}
		else if (c == PERCENT)
		{
			bool started = try_field(&word, &text, exec, &i)!;
			if (started) in_word = true;
		}
		else
		{
			text.append_char(c);
			in_word = true;
			word.has_literal = true;
			i++;
		}
	}
	if (in_quotes) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "unterminated quotation in Exec")~;
	if (in_word) finish_word(words, &word, &text);
}

// Handle the `%` at `exec[*index]` outside quotes. Returns true when it started or extended a word.
fn bool? try_field(Word* word, DString* text, String exec, sz* index) @local
{
	sz i = *index;
	if (i + 1 >= exec.len) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"Exec ends with a lone '%%'"
	)~;
	char code = exec[i + 1];
	*index = i + 2;
	if (code == PERCENT)
	{
		text.append_char(PERCENT);
		word.has_literal = true;
		return true;
	}
	if (is_deprecated_code(code)) return false;
	if (!is_field_code(code))
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "unknown field code '%%%c' in Exec", code)~;
	}
	flush_text(word, text);
	word.parts.push({ .is_field = true, .code = code });
	return true;
}

// Make a new, empty word.
fn Word new_word() @local
{
	Word word;
	word.parts.tinit();
	return word;
}

// Move pending literal text into the word as a part.
fn void flush_text(Word* word, DString* text) @local
{
	if (text.len() == 0) return;
	word.parts.push({ .is_field = false, .text = text.str_view().copy(tmem) });
	text.clear();
}

// Close the current word and start a new one.
fn void finish_word(List{Word}* words, Word* word, DString* text) @local
{
	flush_text(word, text);
	words.push(*word);
	*word = new_word();
}

// Reject word layouts the specification does not allow, and more than one file code.
fn void? validate(Word[] words) @local
{
	int file_codes = 0;
	foreach (&word : words)
	{
		foreach (&part : word.parts)
		{
			if (!part.is_field) continue;
			if (is_file_code(part.code)) file_codes++;
			if (is_standalone_code(part.code) && (word.parts.len() != 1 || word.has_literal))
			{
				return error::raise(
					error::PROTOCOL,
					error::Domain.INTERNAL,
					0,
					"%%%c must be an argument of its own in Exec",
					part.code
				)~;
			}
		}
	}
	if (file_codes > 1) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"Exec has more than one of %%f %%u %%F %%U"
	)~;
}

// How many argument vectors to run: one per file (for %f) or URL (for %u), else one.
fn sz invocation_count(Word[] words, Context context) @local
{
	foreach (&word : words)
	{
		foreach (&part : word.parts)
		{
			if (!part.is_field) continue;
			if (part.code == 'f') return context.files.len > 0 ? context.files.len : 1;
			if (part.code == 'u') return context.urls.len > 0 ? context.urls.len : 1;
		}
	}
	return 1;
}

// The argument vector for invocation `index`, in `allocator`.
fn String[] build_argv(Allocator allocator, Word[] words, Context context, sz index) @local
{
	List{String} argv;
	argv.tinit();
	foreach (&word : words)
	{
		if (word.parts.len() == 1 && word.parts[0].is_field && is_standalone_code(word.parts[0].code))
		{
			append_list_word(&argv, allocator, word.parts[0].code, context);
			continue;
		}
		DString text;
		text.init(tmem);
		foreach (&part : word.parts)
		{
			if (part.is_field)
			{
				text.append_string(field_value(part.code, context, index));
			}
			else
			{
				text.append_string(part.text);
			}
		}
		if (text.len() == 0 && !word.has_literal) continue;
		argv.push(text.str_view().copy(allocator));
	}
	return argv.to_aligned_array(allocator);
}

// The arguments a standalone `%F`, `%U` or `%i` word contributes.
fn void append_list_word(List{String}* argv, Allocator allocator, char code, Context context) @local
{
	switch (code)
	{
		case 'F':
			foreach (file : context.files) argv.push(file.copy(allocator));
		case 'U':
			foreach (url : context.urls) argv.push(url.copy(allocator));
		default:
			if (context.icon.len > 0)
			{
				argv.push(ICON_FLAG.copy(allocator));
				argv.push(context.icon.copy(allocator));
			}
	}
}

// The text one single-valued field code expands to in invocation `index`.
fn String field_value(char code, Context context, sz index) @local
{
	switch (code)
	{
		case 'f': return index < context.files.len ? context.files[index] : "";
		case 'u': return index < context.urls.len ? context.urls[index] : "";
		case 'c': return context.name;
		case 'k': return context.location;
		default: return "";
	}
}

// Characters that a backslash escapes inside double quotes.
fn bool is_quotable(char c) @inline => c == QUOTE || c == '`' || c == '$' || c == ESCAPE;

// Field codes the specification defines and that expand to values.
fn bool is_field_code(char c) @inline
{
	return is_file_code(c) || is_standalone_code(c) || c == 'c' || c == 'k';
}

// `%f %u %F %U`: at most one of these per command line.
fn bool is_file_code(char c) @inline => c == 'f' || c == 'u' || c == 'F' || c == 'U';

// `%F %U %i`: must stand alone as an argument.
fn bool is_standalone_code(char c) @inline => c == 'F' || c == 'U' || c == 'i';

// `%d %D %n %N %v %m`: deprecated by the specification; removed and ignored.
fn bool is_deprecated_code(char c) @inline
{
	return c == 'd' || c == 'D' || c == 'n' || c == 'N' || c == 'v' || c == 'm';
}