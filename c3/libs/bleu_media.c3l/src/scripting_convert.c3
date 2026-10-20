<*
 The text the macOS scripting backend gets back from AppleScript, as a reading.
 Pure: no Apple events. The scripts (`scripting_backend.c3`) send integers only
 (milliseconds and percent), so nothing here parses a floating-point number.

 One line per running player: seven fields separated by tabs, in this order:
 player state, position (ms), sound volume (0 to 100), track length (ms), title,
 artist, album. A stopped or absent player gives an empty line. The text fields
 are last, so a title that contains a tab stays whole: the first four fields
 have no tabs, and the last two tabs separate the artist and the album.
*>
module bleu::media::scripting_convert;
import bleu::error, bleu::media;

<* Number of fields in one reading line. *>
const usz FIELD_COUNT = 7;

<* One player's reading, as text fields borrowed from the line it was parsed from. *>
struct Reading
{
	Playback status;
	long position_ms;
	long volume;
	long length_ms;
	String title;
	String artist;
	String album;
}

// Index of the first tab at or after `start`, or -1 when there is none.
fn sz tab_from(String line, usz start) @private
{
	for (usz i = start; i < line.len; i++)
	{
		if (line[i] == '\t') return (sz)i;
	}
	return -1;
}

<*
 Split `line` into its seven fields. The first four are split at tabs; the title
 is everything up to the second-last tab, so a title may contain tabs; the
 artist and the album are the text after the last two tabs.

 @return "true when the line has all seven fields; the fields then borrow from `line`"
*>
fn bool split_fields(String line, String[FIELD_COUNT]* fields)
{
	usz start = 0;
	for (usz field = 0; field < FIELD_COUNT - 3; field++)
	{
		sz end = tab_from(line, start);
		if (end < 0) return false;
		(*fields)[field] = line[start:(usz)end - start];
		start = (usz)end + 1;
	}
	// The last two tabs in the rest of the line bound the artist; anything before them is the title.
	sz before_artist = -1;
	sz before_album  = -1;
	for (usz i = start; i < line.len; i++)
	{
		if (line[i] != '\t') continue;
		before_artist = before_album;
		before_album = (sz)i;
	}
	if (before_artist < 0) return false;
	(*fields)[4] = line[start:(usz)before_artist - start];
	(*fields)[5] = line[(usz)before_artist + 1:(usz)before_album - (usz)before_artist - 1];
	(*fields)[6] = line[(usz)before_album + 1:line.len - (usz)before_album - 1];
	return true;
}

<* A non-negative integer from decimal text. @return? error::INVALID_ARGUMENT : "Not a decimal integer" *>
fn long? parse_long(String text)
{
	if (text.len == 0) return error::INVALID_ARGUMENT~;
	long value = 0;
	foreach (c : text)
	{
		if (c < '0' || c > '9') return error::INVALID_ARGUMENT~;
		value = value * 10 + (long)(c - '0');
	}
	return value;
}

<* The player state text as a status. Anything else is stopped. *>
fn Playback playback_of_text(String state)
{
	if (state == "playing") return Playback.PLAYING;
	if (state == "paused") return Playback.PAUSED;
	return Playback.STOPPED;
}

<*
 Parse one reading line. An empty line is no reading (the player is not running).

 @return? error::PROTOCOL : "The line does not have seven fields, or a number is not a number"
*>
fn Reading? parse_reading(String line)
{
	if (line.len == 0) return error::PROTOCOL~;
	String[FIELD_COUNT] fields;
	if (!split_fields(line, &fields)) return error::PROTOCOL~;
	long position = parse_long(fields[1]) ?? -1;
	long volume   = parse_long(fields[2]) ?? -1;
	long length   = parse_long(fields[3]) ?? -1;
	if (position < 0 || volume < 0 || length < 0) return error::PROTOCOL~;
	Reading r = {
		.status = playback_of_text(fields[0]),
		.position_ms = position,
		.volume = volume,
		.length_ms = length
	};
	r.title = fields[4];
	r.artist = fields[5];
	r.album = fields[6];
	return r;
}