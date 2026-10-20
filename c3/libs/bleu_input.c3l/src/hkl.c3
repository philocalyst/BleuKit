<*
 Windows input locale identifiers (HKL) and the names Windows gives them, as plain values.

 An HKL is 32 bits. The low word is the language identifier (LANGID); the high word is a device or layout
 handle. The KLID, the eight-digit name that `LoadKeyboardLayoutW` and `GetKeyboardLayoutNameW` use, has
 the layout number in its high four digits and the language in its low four.

 Sources, checked 2026-10-20:
 * Learn, GetKeyboardLayout (https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-getkeyboardlayout):
 "The low word contains a Language Identifier ... the high word contains a device handle".
 * Learn, LoadKeyboardLayoutW: the name is the hex of the language identifier in the low word and a device
 identifier in the high word; "U.S. English ... is named \"00000409\"", its Dvorak layout "00010409".
 * Wine, dlls/user32/input.c, LoadKeyboardLayoutW: a name whose high word is zero gives the HKL
 (LANGID, LANGID), so 00000409 is HKL 0x04090409; a high word of 0xF000 or more is a registry Layout Id.
 The two agree on the cases used here.

 A device-specific HKL (high word 0xF000 or more, not equal to the language) has no KLID that this module can
 derive from the value alone; its id is the HKL value as eight hex digits.
*>
module bleu::input::hkl;

<* Device words from here up name a registry Layout Id, not a KLID layout number (Wine input.c). *>
const uint DEVICE_SPECIFIC_FROM = 0xF000;
const uint WORD_BITS            = 16;
const uint NIBBLE_BITS          = 4;
const uint NIBBLE_MASK          = 0xF;
const usz KLID_DIGITS           = 8;

<* The language identifier (LANGID) in the low word of an HKL. *>
fn ushort language_id(uint hkl) => (ushort)(hkl & 0xFFFF);

<* The high word of an HKL: the device or layout handle. *>
fn uint device_word(uint hkl) => hkl >> WORD_BITS;

<*
 The KLID value of an HKL: the layout number in the high word, the language in the low word. An HKL whose
 device word equals its language (or is zero) has layout number 0. A device-specific HKL is returned
 unchanged.
*>
fn uint klid_value(uint hkl)
{
	uint language = language_id(hkl);
	uint device   = device_word(hkl);
	uint layout   = device == language ? 0 : device;
	if (layout >= DEVICE_SPECIFIC_FROM) return hkl;
	return (layout << WORD_BITS) | language;
}

<*
 The id of an input locale as text: `klid_value` written as eight lowercase hex digits ("00010409").

 @param allocator : "Allocator for the text (not tmem)"
*>
fn String klid_text(uint hkl, Allocator allocator)
{
	uint value = klid_value(hkl);
	char[KLID_DIGITS] digits;
	for (usz i = 0; i < KLID_DIGITS; i++)
	{
		uint nibble = (value >> (uint)(NIBBLE_BITS * (KLID_DIGITS - 1 - i))) & NIBBLE_MASK;
		digits[i] = nibble < 10 ? (char)('0' + nibble) : (char)('a' + nibble - 10);
	}
	return ((String)digits[0:KLID_DIGITS]).copy(allocator);
}

<*
 The LCID for a language identifier. `MAKELCID(lang, SORT_DEFAULT)` with SORT_DEFAULT 0 is the language
 identifier itself (winnls.h; Learn, MAKELCID).
*>
fn uint lcid_of(uint hkl) => language_id(hkl);