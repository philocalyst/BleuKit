<*
 Timestamps and binary values.

 Instants are written as RFC 3339 in UTC with a `Z` suffix, for example
 `"2026-10-20T07:29:00.5Z"`. The fraction keeps only the digits needed for the
 microseconds present, and is omitted when they are zero. Years outside 0 to
 9999 have no RFC 3339 form and are refused.

 Bytes are written as standard base64 (RFC 4648 section 4, with padding).
*>
module bleu::json;
import bleu::error;
import std::time;
import std::time::datetime;
import std::encoding::base64;

<* Longest RFC 3339 text written: `9999-12-31T23:59:59.999999Z`, 27 bytes. *>
const usz TIMESTAMP_CAPACITY = 27;

<* Year range that RFC 3339 can express. *>
const long FIRST_YEAR = 0;
const long LAST_YEAR  = 9999;

<* Digits of the microsecond fraction. *>
const int FRACTION_DIGITS = 6;

<*
 Write `value` into `buffer` at `at`, zero-padded to `width` digits. Returns the
 index after the last digit.
*>
fn sz put_padded(char[] buffer, sz at, long value, int width) @inline
{
	for (int k = width - 1; k >= 0; k--)
	{
		buffer[at + k] = '0' + (char)(value % 10);
		value /= 10;
	}
	return at + width;
}

<*
 Write the wall-clock fields of a UTC instant as a quoted RFC 3339 string.

 @return? error::OUT_OF_RANGE : "The year has no RFC 3339 form"
*>
fn void? JsonWriter.put_fields(&self, long year, long month, long day, long hour, long minute, long second, long micros)
{
	if (year < FIRST_YEAR || year > LAST_YEAR) return error::raise(
		error::OUT_OF_RANGE,
		error::Domain.INTERNAL,
		0,
		"year %d has no RFC 3339 form",
		year
	)~;
	char[TIMESTAMP_CAPACITY] text;
	char[] out = text[..];
	sz at      = put_padded(out, 0, year, 4);
	out[at] = '-';
	at = put_padded(out, at + 1, month, 2);
	out[at] = '-';
	at = put_padded(out, at + 1, day, 2);
	out[at] = 'T';
	at = put_padded(out, at + 1, hour, 2);
	out[at] = ':';
	at = put_padded(out, at + 1, minute, 2);
	out[at] = ':';
	at = put_padded(out, at + 1, second, 2);
	if (micros > 0)
	{
		// Keep only the digits the value needs: 500000 us is ".5", 120 us is ".00012".
		out[at] = '.';
		at++;
		long fraction = micros;
		int digits    = FRACTION_DIGITS;
		while (fraction % 10 == 0)
		{
			fraction /= 10;
			digits--;
		}
		at = put_padded(out, at, fraction, digits);
	}
	out[at] = 'Z';
	at++;
	return self.put_quoted_token((String)out[0:at]);
}

<* Write a `Time` (microseconds since the Unix epoch, UTC) as a quoted RFC 3339 string. *>
fn void? JsonWriter.put_time(&self, Time instant)
{
	DateTime d = datetime::from_time(instant);
	return self.put_fields(
		(long)d.year,
		(long)d.month.ordinal + 1,
		(long)d.day,
		(long)d.hour,
		(long)d.min,
		(long)d.sec,
		(long)d.usec
	);
}

<* Write a `DateTime` as a quoted RFC 3339 string. Its fields are taken to be UTC. *>
fn void? JsonWriter.put_datetime(&self, DateTime d)
{
	return self.put_fields(
		(long)d.year,
		(long)d.month.ordinal + 1,
		(long)d.day,
		(long)d.hour,
		(long)d.min,
		(long)d.sec,
		(long)d.usec
	);
}

<* Write a `TzDateTime` as a quoted RFC 3339 string, converted to UTC first. *>
fn void? JsonWriter.put_tz_datetime(&self, TzDateTime t)
{
	TzDateTime utc = t.to_gmt_offset(0);
	return self.put_datetime(utc.date_time);
}

<*
 Write bytes as a quoted standard base64 string. The base64 text is built in
 temporary memory and needs no escaping.
*>
fn void? JsonWriter.put_bytes(&self, char[] bytes)
{
	@pool()
	{
		return self.put_quoted_token(base64::tencode(bytes));
	};
}

<* Write a token made of characters that need no escaping, between quotation marks. *>
fn void? JsonWriter.put_quoted_token(&self, String token)
{
	self.begin_value()!;
	self.emit("\"")!;
	self.emit(token)!;
	self.emit("\"")!;
	self.end_value();
}