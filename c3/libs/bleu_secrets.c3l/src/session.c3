<*
 The symmetric half of the Secret Service encrypted session.

 After the DH exchange both sides hold the same 1024-bit shared secret. It is
 turned into a 128-bit AES key with HKDF-SHA-256 (RFC 5869) using no salt and an
 empty info string, and each secret is then encrypted with AES-128 in CBC mode
 under PKCS#7 padding, with a fresh 16-byte IV carried in the secret's
 `parameters`. Source: Secret Service API, transfer of secrets, algorithm
 dh-ietf1024-sha256-aes128-cbc-pkcs7 (https://specifications.freedesktop.org/secret-service/latest/ch07s03.html);
 the same construction is in secret-service-4.0.0/src/session.rs `hkdf` and
 util.rs `format_secret`.

 HKDF is written out here because the standard library has HMAC and SHA-256 but
 no HKDF. AES comes from `std::crypto::aes`, which the standard library labels
 "Experimental implementation"; it is checked against openssl in the tests.
*>
module bleu::secrets::session;
import bleu::error, std::hash::sha256, std::crypto::aes, std::crypto::entropy;

<* AES block and key size in bytes (FIPS 197); also the IV size. *>
const sz AES_BLOCK = 16;
<* Length of the AES-128 key derived by HKDF. *>
const sz KEY_BYTES = 16;
<* HMAC-SHA-256 output size, which is the HKDF hash length (RFC 5869 section 2.2). *>
const sz HASH_BYTES = 32;

<*
 HKDF-SHA-256 with no salt (RFC 5869 uses HashLen zero bytes, which is the same
 key for HMAC as an empty one) and an empty info string, producing 16 bytes.

 @param ikm : "The input keying material, the DH shared secret"
 @return "The derived AES-128 key"
*>
fn char[KEY_BYTES] hkdf_sha256_key(char[] ikm)
{
	char[HASH_BYTES] zero_salt = {};
	char[HASH_BYTES] prk = sha256::hmac(zero_salt[..], ikm);
	// Expand: T(1) = HMAC(PRK, info || 0x01), with an empty info string.
	char[1] counter = { 0x01 };
	char[HASH_BYTES] okm = sha256::hmac(prk[..], counter[..]);
	char[KEY_BYTES] key;
	for (sz i = 0; i < KEY_BYTES; i++) key[i] = okm[i];
	return key;
}

<*
 Encrypt with AES-128-CBC and PKCS#7 padding. The output is owned by `allocator`
 and is a whole number of blocks, longer than the input by 1 to 16 bytes.

 @param key : "16 bytes"
 @param iv : "16 random bytes, sent to the service in the secret's parameters"
 @require key.len == KEY_BYTES : "The key must be 16 bytes"
 @require iv.len == AES_BLOCK : "The IV must be 16 bytes"
*>
fn char[]? encrypt_cbc(Allocator allocator, char[] key, char[] iv, char[] plain)
{
	sz padding = AES_BLOCK - plain.len % AES_BLOCK;
	sz padded_len = plain.len + padding;
	@pool()
	{
		char[] padded = alloc::alloc_array(tmem, char, padded_len);
		defer mem::set(padded.ptr, 0, padded.len, 0, true);
		if (plain.len > 0) mem::copy(padded.ptr, plain.ptr, plain.len);
		for (sz i = plain.len; i < padded_len; i++) padded[i] = (char)padding;
		return cbc_encrypt_blocks(allocator, key, iv, padded);
	};
}

// Encrypt whole blocks; `blocks` is already padded.
fn char[]? cbc_encrypt_blocks(Allocator allocator, char[] key, char[] iv, char[] blocks) @local
{
	Aes aes @noinit;
	char[AES_BLOCK] iv_block = block_of(iv);
	aes.init(AES128, key, iv_block, CBC);
	defer aes.destroy();
	return aes.encrypt(allocator, blocks);
}

<*
 Decrypt AES-128-CBC and strip the PKCS#7 padding. The output is owned by `allocator`.

 @param key : "16 bytes"
 @param iv : "16 bytes, from the secret's parameters"
 @require key.len == KEY_BYTES : "The key must be 16 bytes"
 @require iv.len == AES_BLOCK : "The IV must be 16 bytes"
 @return? error::PROTOCOL : "The ciphertext is not whole blocks, or its padding is wrong"
*>
fn char[]? decrypt_cbc(Allocator allocator, char[] key, char[] iv, char[] cipher)
{
	if (cipher.len == 0 || cipher.len % AES_BLOCK != 0)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "ciphertext is not whole AES blocks")~;
	}
	@pool()
	{
		char[] plain = decrypt_blocks(tmem, key, iv, cipher)!;
		defer mem::set(plain.ptr, 0, plain.len, 0, true);
		sz padding = (sz)plain[plain.len - 1];
		if (padding == 0 || padding > AES_BLOCK || padding > plain.len)
		{
			return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "invalid PKCS#7 padding length")~;
		}
		for (sz i = plain.len - padding; i < plain.len; i++)
		{
			if (plain[i] != (char)padding) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "invalid PKCS#7 padding bytes")~;
		}
		return alloc::clone_slice(allocator, plain[0 : plain.len - padding]);
	};
}

// Decrypt whole blocks into `allocator`; the caller strips the padding.
fn char[]? decrypt_blocks(Allocator allocator, char[] key, char[] iv, char[] cipher) @local
{
	Aes aes @noinit;
	char[AES_BLOCK] iv_block = block_of(iv);
	aes.init(AES128, key, iv_block, CBC);
	defer aes.destroy();
	return aes.decrypt(allocator, cipher);
}

// The first block of `bytes`; the caller has checked the length.
fn char[AES_BLOCK] block_of(char[] bytes) @inline
{
	char[AES_BLOCK] block;
	for (sz i = 0; i < AES_BLOCK; i++) block[i] = bytes[i];
	return block;
}

<*
 A fresh random IV for one encryption.

 @return? error::BACKEND_FAILURE : "The entropy source failed"
*>
fn char[AES_BLOCK]? random_iv()
{
	char[AES_BLOCK] iv;
	if (catch err = entropy::fill(iv[..]))
	{
		return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "no secure random bytes for an IV")~;
	}
	return iv;
}
