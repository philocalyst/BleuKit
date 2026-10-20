module bleu::secrets::dh_test;
import bleu::error, bleu::secrets::bignum, bleu::secrets::dh, bleu::secrets::bignum_test;

fn void exponentiation_of_the_generator() @test
{
	Montgomery g = dh::group()!!;
	Num five     = { };
	five.limbs[0] = 5;
	// 2^5 = 32.
	Num public = dh::dh_public(&g, &five);
	char[128] out;
	public.to_be(out[..]);
	assert(out[127] == 32 && out[126] == 0);
}

fn void both_sides_agree_on_the_secret() @test
{
	Montgomery g = dh::group()!!;
	Num a        = { };
	a.limbs[0] = 5;
	Num b = { };
	b.limbs[0] = 7;
	Num pub_a = dh::dh_public(&g, &a);
	Num pub_b = dh::dh_public(&g, &b);
	char[128] from_a;
	char[128] from_b;
	dh::dh_shared(&g, &a, &pub_b, from_a[..])!!;
	dh::dh_shared(&g, &b, &pub_a, from_b[..])!!;
	assert(from_a[..] == from_b[..], "g^(ab) must be the same from both sides");
	// 2^(5*7) = 2^35 = 0x8_0000_0000, written in 128 bytes.
	assert(from_a[127] == 0x00 && from_a[123] == 0x08 && from_a[122] == 0x00, "2^35 is 0x800000000");
}

fn void peers_outside_the_group_are_refused() @test
{
	Montgomery g = dh::group()!!;
	Num a        = { };
	a.limbs[0] = 5;
	char[128] out;
	Num zero = { };
	Num one  = { };
	one.limbs[0] = 1;
	Num p_minus_one = g.modulus;
	p_minus_one.sub_assign(&one);
	assert(@catch(dh::dh_shared(&g, &a, &zero, out[..])) == error::PROTOCOL);
	assert(@catch(dh::dh_shared(&g, &a, &one, out[..])) == error::PROTOCOL);
	assert(@catch(dh::dh_shared(&g, &a, &p_minus_one, out[..])) == error::PROTOCOL);
}

fn void the_prime_in_the_module_is_the_rfc_prime() @test
{
	Num from_module = bignum::from_be(dh::PRIME_BE[..])!!;
	Num from_test = bignum::from_be(
		bignum_test::unhex(
			tmem,
			"FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF"
		)!!
	)!!;
	assert(from_module.compare(&from_test) == 0);
}

fn void private_keys_are_fresh() @test
{
	Num a = dh::random_private()!!;
	Num b = dh::random_private()!!;
	assert(!a.is_zero() && a.compare(&b) != 0, "two 1024-bit random exponents collide only by bad luck");
}