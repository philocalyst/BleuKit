<*
 Fixed-size 1024-bit integers and modular exponentiation.

 The Secret Service DH key exchange needs `base^exponent mod p` for a 1024-bit
 prime and nothing else, so this file implements exactly that over a `Num` of
 32 little-endian 32-bit limbs. Multiplication modulo an odd modulus uses
 Montgomery's method in the coarsely integrated operand scanning form (Koc,
 Acar and Kaliski, "Analyzing and Comparing Montgomery Multiplication
 Algorithms", IEEE Micro 16(3), 1996, Algorithm 2).

 Not constant time: the exponentiation branches on exponent bits. The exchange
 runs once per session on the user's own machine, so this is recorded as a
 limit rather than hidden.
*>
module bleu::secrets::bignum;
import bleu::error;

<* Limbs in a `Num`: 1024 bits in 32-bit words. *>
const sz LIMBS = 32;
<* Bytes in a `Num` written big-endian. *>
const sz BYTES = 128;
<* Bits in a `Num`. *>
const sz BITS = 1024;
<* Bits in one limb. *>
const sz LIMB_BITS = 32;

<* A 1024-bit unsigned integer; `limbs[0]` is the least significant word. *>
struct Num
{
	uint[LIMBS] limbs;
}

<*
 Parse big-endian bytes; shorter input is zero-extended, leading zeros are allowed.

 @param bytes : "At most 128 bytes"
 @return? error::INVALID_ARGUMENT : "More than 128 bytes were given"
*>
fn Num? from_be(char[] bytes)
{
	if (bytes.len > BYTES) return error::INVALID_ARGUMENT~;
	Num n = {};
	for (sz i = 0; i < bytes.len; i++)
	{
		sz from_low = bytes.len - 1 - i;
		n.limbs[i / 4] |= (uint)bytes[from_low] << (uint)(8 * (i % 4));
	}
	return n;
}

<*
 Write all 128 bytes, big-endian, leading zeros included.

 @param [out] out : "A buffer of exactly 128 bytes"
 @require out.len == BYTES : "The output must be 128 bytes"
*>
fn void Num.to_be(&self, char[] out)
{
	for (sz i = 0; i < BYTES; i++)
	{
		sz from_low = BYTES - 1 - i;
		out[i] = (char)(self.limbs[from_low / 4] >> (uint)(8 * (from_low % 4)));
	}
}

<*
 The shortest big-endian form of the number, as the Secret Service requires for
 public keys. Zero is written as one zero byte. The result is owned by `allocator`.
*>
fn char[] Num.to_be_minimal(&self, Allocator allocator)
{
	char[BYTES] full;
	self.to_be(full[..]);
	sz first = 0;
	while (first < BYTES - 1 && full[first] == 0) first++;
	return alloc::clone_slice(allocator, full[first : BYTES - first]);
}

<* True for zero. *>
fn bool Num.is_zero(&self) @inline
{
	for (sz i = 0; i < LIMBS; i++)
	{
		if (self.limbs[i] != 0) return false;
	}
	return true;
}

<* Bit `index` (0 is the least significant). *>
fn bool Num.bit(&self, sz index) @inline => ((self.limbs[index / LIMB_BITS] >> (uint)(index % LIMB_BITS)) & 1) != 0;

<* -1, 0 or 1 as `self` is less than, equal to or greater than `other`. *>
fn int Num.compare(&self, Num* other)
{
	for (sz i = LIMBS - 1; i >= 0; i--)
	{
		if (self.limbs[i] != other.limbs[i]) return self.limbs[i] < other.limbs[i] ? -1 : 1;
	}
	return 0;
}

<* `self -= other` modulo 2^1024. Returns true when the subtraction borrowed (self was smaller). *>
fn bool Num.sub_assign(&self, Num* other)
{
	ulong borrow = 0;
	for (sz i = 0; i < LIMBS; i++)
	{
		// The 64-bit difference wraps negative only when the top bit is set,
		// because both operands fit in 32 bits.
		ulong diff = (ulong)self.limbs[i] - (ulong)other.limbs[i] - borrow;
		self.limbs[i] = (uint)diff;
		borrow = diff >> 63;
	}
	return borrow != 0;
}

<* Shift left by one bit. Returns the bit that fell off the top. *>
fn bool Num.shl1(&self)
{
	uint carry = 0;
	for (sz i = 0; i < LIMBS; i++)
	{
		uint next = self.limbs[i] >> 31;
		self.limbs[i] = (self.limbs[i] << 1) | carry;
		carry = next;
	}
	return carry != 0;
}

<* `self = 2 * self mod modulus`, for `self < modulus`. *>
fn void Num.double_mod(&self, Num* modulus)
{
	bool overflow = self.shl1();
	if (overflow || self.compare(modulus) >= 0) self.sub_assign(modulus);
}

<*
 Montgomery arithmetic for one odd modulus. Build it once with `montgomery_for`.

 `one` and `r2` are 2^1024 and 2^2048 modulo the modulus; `n0` is
 -modulus^-1 modulo 2^32.
*>
struct Montgomery
{
	Num modulus;
	uint n0;
	Num one;
	Num r2;
}

<*
 Precompute the Montgomery constants for `modulus`.

 @param modulus : "An odd number greater than 2"
 @return? error::INVALID_ARGUMENT : "The modulus is even or too small"
*>
fn Montgomery? montgomery_for(Num modulus)
{
	Num two = {};
	two.limbs[0] = 2;
	if (modulus.limbs[0] % 2 == 0 || modulus.compare(&two) <= 0) return error::INVALID_ARGUMENT~;
	Montgomery m = { .modulus = modulus };
	// Newton iteration for the inverse of an odd word modulo 2^32: each step doubles the correct bits.
	uint inverse = modulus.limbs[0];
	for (int step = 0; step < 5; step++) inverse *= 2 - modulus.limbs[0] * inverse;
	m.n0 = 0 - inverse;
	// one = 2^1024 mod p: start from 1 and double 1024 times.
	m.one.limbs[0] = 1;
	for (sz i = 0; i < BITS; i++) m.one.double_mod(&modulus);
	// r2 = 2^2048 mod p: keep doubling.
	m.r2 = m.one;
	for (sz i = 0; i < BITS; i++) m.r2.double_mod(&modulus);
	return m;
}

<*
 Montgomery product a * b * R^-1 mod modulus, for a and b below the modulus.

 Coarsely integrated operand scanning: each outer step adds a[*] * b[i], then
 adds a multiple of the modulus that clears the lowest word.
*>
fn Num Montgomery.mul(&self, Num* a, Num* b)
{
	uint[LIMBS + 2] t = {};
	for (sz i = 0; i < LIMBS; i++)
	{
		ulong carry = 0;
		for (sz j = 0; j < LIMBS; j++)
		{
			ulong cur = (ulong)t[j] + (ulong)a.limbs[j] * (ulong)b.limbs[i] + carry;
			t[j] = (uint)cur;
			carry = cur >> 32;
		}
		ulong top = (ulong)t[LIMBS] + carry;
		t[LIMBS] = (uint)top;
		t[LIMBS + 1] = (uint)(top >> 32);

		uint m = t[0] * self.n0;
		carry = ((ulong)t[0] + (ulong)m * (ulong)self.modulus.limbs[0]) >> 32;
		for (sz j = 1; j < LIMBS; j++)
		{
			ulong cur = (ulong)t[j] + (ulong)m * (ulong)self.modulus.limbs[j] + carry;
			t[j - 1] = (uint)cur;
			carry = cur >> 32;
		}
		top = (ulong)t[LIMBS] + carry;
		t[LIMBS - 1] = (uint)top;
		t[LIMBS] = t[LIMBS + 1] + (uint)(top >> 32);
	}
	Num result = {};
	for (sz i = 0; i < LIMBS; i++) result.limbs[i] = t[i];
	// The result is below 2 * modulus, so one subtraction reduces it.
	if (t[LIMBS] != 0 || result.compare(&self.modulus) >= 0) result.sub_assign(&self.modulus);
	return result;
}

<*
 base^exponent modulo the modulus, by left-to-right square-and-multiply in
 Montgomery form.

 @param base : "Already reduced: below the modulus"
 @param exponent : "Any 1024-bit value"
 @require base.compare(&self.modulus) < 0 : "The base must be reduced modulo the modulus"
*>
fn Num Montgomery.pow(&self, Num* base, Num* exponent)
{
	Num base_m = self.mul(base, &self.r2);
	Num acc = self.one;
	for (sz i = BITS - 1; i >= 0; i--)
	{
		acc = self.mul(&acc, &acc);
		if (exponent.bit(i)) acc = self.mul(&acc, &base_m);
	}
	Num plain_one = {};
	plain_one.limbs[0] = 1;
	return self.mul(&acc, &plain_one);
}
