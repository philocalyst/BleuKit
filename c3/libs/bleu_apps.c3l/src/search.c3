module bleu::apps;
import std::collections::list, bleu::error;

<*
 Ranking for a launcher's search box. A pure function of the catalogue: no I/O,
 no clock, no state of its own.

 The query is split on spaces. Every word must match at least one field of an
 app, or the app is left out. An app's score is the sum over the words of the
 best field match for that word, plus the consumer's `Ranker` bonus (frecency,
 pinning, anything the catalogue cannot know). Ties are broken by catalogue
 order, so the same query on the same state always gives the same list.

 A word matches a text, case-insensitively and byte by byte, in the first of
 these ways that holds, scoring 1000 down to 0:
 1000 the text is the word;
 800 the text starts with the word;
 600 the word starts after a separator (space, dash, dot, slash, ...);
 400 the word occurs somewhere in the text;
 1..100 the letters of the word occur in order (fuzzy): 100 * word length / span.
 The fields have weights in percent: name 100, generic name 60, keywords 60,
 the program name (basename of the first word of `target`) 50, comment 20.
 So "fire" ranks Firefox (name prefix, 800) above an app whose comment mentions
 fire (400 * 20 %), and a query that matches only the comment still finds it.
*>
alias Ranker = fn int(void* context, App* app);

const int SCORE_EXACT     = 1000;
const int SCORE_PREFIX    = 800;
const int SCORE_WORD      = 600;
const int SCORE_SUBSTRING = 400;
const int SCORE_FUZZY_MAX = 100;

const int WEIGHT_NAME    = 100;
const int WEIGHT_GENERIC = 60;
const int WEIGHT_KEYWORD = 60;
const int WEIGHT_PROGRAM = 50;
const int WEIGHT_COMMENT = 20;
const int PERCENT        = 100;

<* One matching app: its index in `State.apps`, and its score (higher is better). *>
struct SearchHit
{
	usz index;
	int score;
}

<*
 Rank the apps of `state` against `query`. Returns the matches, best first.

 @param state : "The catalogue to search; its apps are indexed by `SearchHit.index`"
 @param query : "What the user typed; empty lists every app, in catalogue order"
 @param ranker : "Optional bonus per app (may be null); added to the score of matching apps"
 @param context : "Passed to `ranker` unchanged"
 @param [&inout] allocator : "Allocator for the returned array"
 @return? error::NO_MEMORY : "never; allocation failure aborts"
*>
fn SearchHit[] rank(State* state, String query, Ranker ranker, void* context, Allocator allocator)
{
	String[] words = query_words(query);
	List{SearchHit} hits;
	hits.tinit();
	foreach (i, &app : state.apps)
	{
		int total        = 0;
		bool all_matched = true;
		foreach (word : words)
		{
			int best = best_field_score(app, word);
			if (best == 0)
			{
				all_matched = false;
				break;
			}
			total += best;
		}
		if (!all_matched) continue;
		// The ranker orders matches of a query; an empty query lists the catalogue in its own order.
		if (ranker && words.len > 0) total += ranker(context, app);
		hits.push({ .index = (usz)i, .score = total });
	}
	sort_hits(hits.array_view());
	return hits.to_aligned_array(allocator);
}

<* The words of `query`, separated by spaces; empty words dropped. Temporary. *>
fn String[] query_words(String query) @local
{
	List{String} words;
	words.tinit();
	foreach (word : query.tsplit(" ", 0, true)) words.push(word);
	return words.to_tarray();
}

// The best score of `word` over every field of `app`; 0 when no field matches.
fn int best_field_score(App* app, String word) @local
{
	int best = field_score(app.name, word, WEIGHT_NAME);
	best = max(best, field_score(app.generic_name, word, WEIGHT_GENERIC));
	best = max(best, field_score(app.comment, word, WEIGHT_COMMENT));
	best = max(best, field_score(program_name(app), word, WEIGHT_PROGRAM));
	foreach (keyword : app.keywords) best = max(best, field_score(keyword, word, WEIGHT_KEYWORD));
	return best;
}

// `match_score` of one field, scaled by the field's weight in percent.
fn int field_score(String text, String word, int weight) @local
{
	return match_score(text, word) * weight / PERCENT;
}

<*
 The score of `word` against `text` on the 0..1000 scale of this module. Zero
 means no match.
*>
fn int match_score(String text, String word)
{
	if (word.len == 0 || !fuzzy_possible(text, word)) return 0;
	if (text.len == word.len && same_at(text, 0, word)) return SCORE_EXACT;
	if (same_at(text, 0, word)) return SCORE_PREFIX;
	bool word_start = false;
	bool anywhere   = false;
	for (usz i = 0; i + word.len <= text.len; i++)
	{
		if (!same_at(text, i, word)) continue;
		anywhere = true;
		if (i == 0 || is_separator(text[i - 1]))
		{
			word_start = true;
			break;
		}
	}
	if (word_start) return SCORE_WORD;
	if (anywhere) return SCORE_SUBSTRING;
	return fuzzy_score(text, word);
}

// Whether the letters of `word` can occur in order in `text` (a cheap pre-check).
fn bool fuzzy_possible(String text, String word) @local
{
	usz at = 0;
	foreach (c : word)
	{
		while (at < text.len && fold(text[at]) != fold(c)) at++;
		if (at == text.len) return false;
		at++;
	}
	return true;
}

// Fuzzy score: the word's letters in order, scaled by how tightly the tightest match sits together.
fn int fuzzy_score(String text, String word) @local
{
	if (word.len == 0) return 0;
	usz tightest = 0;
	for (usz start = 0; start < text.len; start++)
	{
		if (fold(text[start]) != fold(word[0])) continue;
		usz span = greedy_span(text, word, start);
		if (span > 0 && (tightest == 0 || span < tightest)) tightest = span;
	}
	if (tightest == 0) return 0;
	return (int)(SCORE_FUZZY_MAX * word.len / tightest);
}

// The span in bytes of the greedy match of `word` in `text` that begins at `start`; zero when it does not match.
fn usz greedy_span(String text, String word, usz start) @local
{
	usz at   = start;
	usz last = start;
	foreach (i, c : word)
	{
		while (at < text.len && fold(text[at]) != fold(c)) at++;
		if (at == text.len) return 0;
		last = at;
		at++;
	}
	return last - start + 1;
}

// Whether `word` occurs in `text` at byte `at`, ignoring ASCII case.
fn bool same_at(String text, usz at, String word) @local
{
	if (at + word.len > text.len) return false;
	for (usz i = 0; i < word.len; i++)
	{
		if (fold(text[at + i]) != fold(word[i])) return false;
	}
	return true;
}

// ASCII lower-case of one byte; other bytes, UTF-8 included, are left as they are.
fn char fold(char c) @inline => c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c;

// Characters that start a new word in a name such as "Visual Studio Code" or "org.gnome.Maps".
fn bool is_separator(char c) @inline
{
	return !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c >= 0x80);
}

<*
 The program name a launcher shows for `app`: the basename of the first word of
 `target` for an `EXEC` app, the basename of the target otherwise. Temporary.
*>
fn String program_name(App* app)
{
	String target = app.target;
	if (app.launch == EXEC)
	{
		usz space = target.len;
		for (usz i = 0; i < target.len; i++)
		{
			if (target[i] != ' ') continue;
			space = i;
			break;
		}
		target = target[:space];
	}
	usz start = 0;
	for (usz i = 0; i < target.len; i++)
	{
		if (target[i] == '/' || target[i] == '\\') start = i + 1;
	}
	return target[start..];
}

// Insertion sort: the hit lists are short, and insertion sort is stable.
fn void sort_hits(SearchHit[] hits) @local
{
	for (usz i = 1; i < hits.len; i++)
	{
		SearchHit current = hits[i];
		usz j             = i;
		while (j > 0 && better(current, hits[j - 1]))
		{
			hits[j] = hits[j - 1];
			j--;
		}
		hits[j] = current;
	}
}

// Higher score first; equal scores keep catalogue order.
fn bool better(SearchHit a, SearchHit b) @inline => a.score > b.score || (a.score == b.score && a.index < b.index);