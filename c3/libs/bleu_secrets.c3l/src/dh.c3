<*
 Group parameters of the Secret Service `dh-ietf1024-sha256-aes128-cbc-pkcs7`
 algorithm, and the two DH operations it needs.

 Prime: RFC 2409 section 6.2, the Second Oakley Group (1024-bit MODP). Checked
 against the hexadecimal value there, against the bytes used by the
 secret-service crate (`secret-service-4.0.0/src/session.rs` lines 36-44,
 https://static.crates.io/crates/secret-service/secret-service-4.0.0.crate),
 and against the RFC's closed form 2^1024 - 2^960 - 1 + 2^64 * (floor(2^894 pi) + 129093).
 Generator: 2 (RFC 2409 section 6.2; crate session.rs DH_GENERATOR).
 Secret Service spec, algorithm section 7.3: "DH key agreement [rfc2631] ...
 using 1024 bit parameters of the standard IETF 'Second Oakley Group' [rfc2409]".
*>
module bleu::secrets::dh;
import bleu::error, bleu::secrets::bignum, std::crypto::entropy;

<* Bytes in a group element. *>
const sz ELEMENT_BYTES = 128;

<* The RFC 2409 group 2 prime, big-endian. *>
const char[ELEMENT_BYTES] PRIME_BE = {
	0xFF,
	0xFF,
	0xFF,
	0xFF,
	0xFF,
	0xFF,
	0xFF,
	0xFF,
	0xC9,
	0x0F,
	0xDA,
	0xA2,
	0x21,
	0x68,
	0xC2,
	0x34,
	0xC4,
	0xC6,
	0x62,
	0x8B,
	0x80,
	0xDC,
	0x1C,
	0xD1,
	0x29,
	0x02,
	0x4E,
	0x08,
	0x8A,
	0x67,
	0xCC,
	0x74,
	0x02,
	0x0B,
	0xBE,
	0xA6,
	0x3B,
	0x13,
	0x9B,
	0x22,
	0x51,
	0x4A,
	0x08,
	0x79,
	0x8E,
	0x34,
	0x04,
	0xDD,
	0xEF,
	0x95,
	0x19,
	0xB3,
	0xCD,
	0x3A,
	0x43,
	0x1B,
	0x30,
	0x2B,
	0x0A,
	0x6D,
	0xF2,
	0x5F,
	0x14,
	0x37,
	0x4F,
	0xE1,
	0x35,
	0x6D,
	0x6D,
	0x51,
	0xC2,
	0x45,
	0xE4,
	0x85,
	0xB5,
	0x76,
	0x62,
	0x5E,
	0x7E,
	0xC6,
	0xF4,
	0x4C,
	0x42,
	0xE9,
	0xA6,
	0x37,
	0xED,
	0x6B,
	0x0B,
	0xFF,
	0x5C,
	0xB6,
	0xF4,
	0x06,
	0xB7,
	0xED,
	0xEE,
	0x38,
	0x6B,
	0xFB,
	0x5A,
	0x89,
	0x9F,
	0xA5,
	0xAE,
	0x9F,
	0x24,
	0x11,
	0x7C,
	0x4B,
	0x1F,
	0xE6,
	0x49,
	0x28,
	0x66,
	0x51,
	0xEC,
	0xE6,
	0x53,
	0x81,
	0xFF,
	0xFF,
	0xFF,
	0xFF,
	0xFF,
	0xFF,
	0xFF,
	0xFF,
};

<* The generator. *>
const uint GENERATOR = 2;

<*
 The Montgomery context for the group. Cheap enough to rebuild per session.
*>
fn Montgomery? group()
{
	Num prime = bignum::from_be(PRIME_BE[..])!;
	return bignum::montgomery_for(prime);
}

<*
 A fresh exponent exponent: 128 bytes from the operating system's entropy
 source, as the crate does (`Keypair::generate`).

 @return? error::BACKEND_FAILURE : "The entropy source failed"
*>
fn Num? random_private()
{
	char[ELEMENT_BYTES] bytes;
	defer mem::set(bytes[..].ptr, 0, bytes.len, 0, true);
	if (catch err = entropy::fill(bytes[..]))
	{
		return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.INTERNAL,
			0,
			"no secure random bytes for the DH key"
		)~;
	}
	return bignum::from_be(bytes[..]);
}

<*
 The public value GENERATOR^exponent mod p, to send in OpenSession.

 @param [&in] group : "The group context from `group()`"
 @param [&in] exponent : "An exponent from `random_private()`"
*>
fn Num dh_public(Montgomery* group, Num* exponent)
{
	Num generator = { };
	generator.limbs[0] = GENERATOR;
	return group.pow(&generator, exponent);
}

<*
 The shared secret peer^exponent mod p, written as 128 big-endian bytes with
 leading zeros, which is what the secret-service crate feeds into HKDF.

 The peer value must lie strictly between 1 and p - 1: a service that sends
 0, 1 or p - 1 would force a known shared secret.

 @param [&in] group : "The group context from `group()`"
 @param [out] out : "A buffer of exactly 128 bytes"
 @return? error::PROTOCOL : "The peer's public value is outside 1 .. p-2"
*>
fn void? dh_shared(Montgomery* group, Num* exponent, Num* peer, char[] out)
{
	Num one = { };
	one.limbs[0] = 1;
	Num p_minus_one = group.modulus;
	p_minus_one.sub_assign(&one);
	if (peer.compare(&one) <= 0 || peer.compare(&p_minus_one) >= 0)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "DH public value out of range")~;
	}
	Num shared = group.pow(peer, exponent);
	defer mem::set(&shared, 0, bignum::BYTES, 0, true);
	shared.to_be(out);
}