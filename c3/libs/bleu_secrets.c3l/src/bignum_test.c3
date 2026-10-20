module bleu::secrets::bignum_test;
import bleu::error, bleu::secrets::bignum, bleu::secrets::bignum_vectors_test;

// Hex text to bytes; test-only, so an invalid digit is a test bug and asserts.
fn char[]? unhex(Allocator allocator, String hex)
{
	char[] out = alloc::alloc_array(allocator, char, hex.len / 2);
	for (sz i = 0; i < out.len; i++)
	{
		out[i] = (char)((nibble(hex[2 * i]) << 4) | nibble(hex[2 * i + 1]));
	}
	return out;
}

fn char nibble(char c) @local
{
	if (c >= '0' && c <= '9') return (char)(c - '0');
	if (c >= 'a' && c <= 'f') return (char)(c - 'a' + 10);
	unreachable("not a hex digit");
}

fn void matches_python_pow() @test
{
	Montgomery m = bignum::montgomery_for(bignum::from_be(dh_prime())!!)!!;
	char[128] out;
	foreach (row : bignum_vectors_test::DH_VECTORS)
	{
		Num y = bignum::from_be(unhex(tmem, row[0])!!)!!;
		Num x = bignum::from_be(unhex(tmem, row[1])!!)!!;
		Num got = m.pow(&y, &x);
		got.to_be(out[..]);
		assert(out[..] == unhex(tmem, row[2])!!, "pow(y, x, p) disagrees with python");
	}
}

// The RFC 2409 prime, written out here as well, so a typo in dh.c3 cannot pass unnoticed.
fn char[] dh_prime() @local
{
	return unhex(tmem, "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF")!!;
}

fn void bytes_round_trip() @test
{
	char[] input = unhex(tmem, "0080000000000000000000000000000000000000000000000000000000000000ff")!!;
	Num n = bignum::from_be(input)!!;
	char[128] full;
	n.to_be(full[..]);
	assert(full[0] == 0 && full[127] == 0xFF && full[1] == 0);
	char[] shortest = n.to_be_minimal(tmem);
	assert(shortest.len == input.len && shortest[0] == 0x00 && shortest[1] == 0x80);
	assert(bignum::from_be(unhex(tmem, "00")!!)!!.is_zero());
	Num zero_num = {};
	char[] zero = zero_num.to_be_minimal(tmem);
	assert(zero.len == 1 && zero[0] == 0, "zero is written as one byte");
}

fn void too_long_input_is_refused() @test
{
	char[129] too_long;
	assert(@catch(bignum::from_be(too_long[..])) == error::INVALID_ARGUMENT);
}

fn void even_or_tiny_moduli_are_refused() @test
{
	Num even = {};
	even.limbs[0] = 10;
	assert(@catch(bignum::montgomery_for(even)) == error::INVALID_ARGUMENT);
	Num one = {};
	one.limbs[0] = 1;
	assert(@catch(bignum::montgomery_for(one)) == error::INVALID_ARGUMENT);
}

fn void small_modulus_matches_hand_arithmetic() @test
{
	// 7 is prime, so 3^6 = 1 mod 7 and 3^100 = 3^(100 mod 6) = 3^4 = 81 = 4 mod 7.
	Num seven = {};
	seven.limbs[0] = 7;
	Montgomery m = bignum::montgomery_for(seven)!!;
	Num three = {};
	three.limbs[0] = 3;
	Num hundred = {};
	hundred.limbs[0] = 100;
	Num got = m.pow(&three, &hundred);
	assert(got.limbs[0] == 4 && got.limbs[1] == 0);
}
