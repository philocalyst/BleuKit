<*
 The text the macOS scripting backend gets back from AppleScript, as a reading.
 Pure: no Apple events. The scripts (`scripting_backend.c3`) send integers only
 (milliseconds and percent), so nothing here parses a floating-point number.

 One line per running player: seven fields separated by tabs, in this order:
 player state, position (ms), sound volume (0 to 100), track length (ms), title,
 artist, album. A stopped or absent player gives an empty line.
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

<*
 Split `line` into its seven tab-separated fields.

 @return "true when the line has exactly seven fields; the fields then borrow from `line`"
*>
fn bool split_fields(String line, String[FIELD_COUNT]* fields)
{
	usz field = 0;
	usz start = 0;
	for (usz i = 0; i <= line.len; i++)
	{
		if (i < line.len && line[i] != '\t') continue;
		if (field >= FIELD_COUNT) return false;
		(*fields)[field] = line[start:i - start];
		field++;
		start = i + 1;
	}
	return field == FIELD_COUNT;
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