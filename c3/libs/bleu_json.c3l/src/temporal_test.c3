module bleu::json;
import bleu::error;
import std::time;
import std::time::datetime;

<* Write one value through a fresh writer into `out` and return the text. *>
fn String text_of_time(DString* out, Time instant)
{
	out.clear();
	JsonWriter w;
	w.init_dstring(out);
	w.put_time(instant)!!;
	return out.str_view();
}

fn void instants_are_rfc3339_utc() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	assert(text_of_time(&out, (Time)0) == `"1970-01-01T00:00:00Z"`);
	assert(text_of_time(&out, (Time)1_500_000) == `"1970-01-01T00:00:01.5Z"`);
	assert(text_of_time(&out, (Time)-1_000_000) == `"1969-12-31T23:59:59Z"`);
	assert(text_of_time(&out, (Time)120) == `"1970-01-01T00:00:00.00012Z"`);
	assert(text_of_time(&out, (Time)951782400_000_000) == `"2000-02-29T00:00:00Z"`);
	assert(text_of_time(&out, (Time)1_790_000_000_123_456) == `"2026-09-21T14:13:20.123456Z"`);
}

fn void years_outside_rfc3339_are_refused() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	JsonWriter w;
	w.init_dstring(&out);
	// 253402300800 s is 10000-01-01T00:00:00Z, the first year RFC 3339 cannot write.
	if (catch w.put_time((Time)253402300800_000_000))
	{
		assert(error::last().status == error::Status.OUT_OF_RANGE);
	}
	else
	{
		assert(false);
	}
	assert(out.str_view() == "");
}

fn void datetimes_and_tz_datetimes_convert_to_utc() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	JsonWriter w;
	w.init_dstring(&out);
	DateTime d = datetime::at(2026, OCTOBER, 20, 7, 29, 0);
	w.begin_array()!!;
	w.put_datetime(d)!!;
	TzDateTime t = datetime::at_tz(2026, OCTOBER, 20, 12, 0, 0, 0, 3600);
	w.put_tz_datetime(t)!!;
	w.end_array()!!;
	assert(out.str_view() == `["2026-10-20T07:29:00Z","2026-10-20T11:00:00Z"]`);
}

fn void bytes_are_standard_base64() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	JsonWriter w;
	w.init_dstring(&out);
	w.begin_array()!!;
	w.put_bytes("")!!;
	w.put_bytes("f")!!;
	w.put_bytes("fo")!!;
	w.put_bytes("foo")!!;
	w.end_array()!!;
	assert(out.str_view() == `["","Zg==","Zm8=","Zm9v"]`);
}