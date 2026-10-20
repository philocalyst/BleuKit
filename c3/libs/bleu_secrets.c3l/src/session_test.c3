module bleu::secrets::session_test;
import bleu::error, bleu::secrets::session, bleu::secrets::session_vectors_test, bleu::secrets::bignum_test;

fn void hkdf_matches_hmac_vectors() @test
{
	foreach (row : session_vectors_test::HKDF_VECTORS)
	{
		char[] ikm   = bignum_test::unhex(tmem, row[0])!!;
		char[16] key = session::hkdf_sha256_key(ikm);
		assert(key[..] == bignum_test::unhex(tmem, row[1])!!, "HKDF-SHA256 disagrees with python hmac");
	}
}

fn void cbc_matches_openssl() @test
{
	foreach (row : session_vectors_test::CBC_VECTORS)
	{
		char[] key   = bignum_test::unhex(tmem, row[0])!!;
		char[] iv    = bignum_test::unhex(tmem, row[1])!!;
		char[] plain = bignum_test::unhex(tmem, row[2])!!;
		char[] want  = bignum_test::unhex(tmem, row[3])!!;
		char[] got   = session::encrypt_cbc(tmem, key, iv, plain)!!;
		assert(got == want, "AES-128-CBC/PKCS#7 disagrees with openssl enc");
		char[] back = session::decrypt_cbc(tmem, key, iv, got)!!;
		assert(back == plain, "decrypt inverts encrypt");
	}
}

fn void wrong_padding_is_a_protocol_error() @test
{
	char[16] key        = { };
	char[16] iv         = { };
	// Decrypting garbage almost always gives bad padding; a whole-block zero plaintext has padding 0.
	char[16] zero_block = { };
	char[] cipher       = session::encrypt_cbc(tmem, key[..], iv[..], zero_block[..])!!;
	// Flip the ciphertext's last byte: the last plaintext block changes, so padding breaks.
	cipher[cipher.len - 1] ^= 0x55;
	assert(@catch(session::decrypt_cbc(tmem, key[..], iv[..], cipher)) == error::PROTOCOL);
}

fn void ragged_ciphertext_is_refused() @test
{
	char[16] key = { };
	char[16] iv  = { };
	char[15] short_block;
	assert(@catch(session::decrypt_cbc(tmem, key[..], iv[..], short_block[..])) == error::PROTOCOL);
}