// Helpers shared by the bleu_dbus unit tests: hex fixtures and byte comparison.
module bleu::dbus::testing;
import std::io, bleu::error;

<*
 Decode hex text (pairs of digits, spaces ignored) into bytes allocated from
 the temporary allocator. Call inside a `@pool()`.
*>
fn String from_hex(String text)
{
	DString out;
	out.init(tmem);
	int high = -1;
	foreach (c : text)
	{
		int nibble = digit_value(c);
		if (nibble < 0) continue;
		if (high < 0)
		{
			high = nibble;
		}
		else
		{
			out.append_char((char)(high * 16 + nibble));
			high = -1;
		}
	}
	return out.str_view();
}

// The value of a hex digit, or -1 for any other character.
fn int digit_value(char c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

<*
 Assert that `bytes` equals the hex fixture `hex`, printing both on mismatch.
 Call inside a `@pool()`.
*>
fn void expect_bytes(String bytes, String hex)
{
	String want = from_hex(hex);
	if (bytes == want) return;
	io::printfn("expected %d bytes: %s", want.len, hex);
	io::printfn("got      %d bytes", bytes.len);
	for (usz i = 0; i < bytes.len; i++) io::printf("%02x ", bytes[i]);
	io::printn("");
	unreachable("bytes differ from the golden vector");
}

<*
 Assert that the call `result` fails with the fault `expected`.
*>
macro @expect_fault(#result, expected)
{
	bool failed = false;
	if (catch err = #result)
	{
		assert(err == expected, "wrong fault");
		failed = true;
	}
	assert(failed, "the call should have failed");
}
