<*
 `Value`: a D-Bus value as a dynamic tree, for code that does not know the
 shape of a reply until it arrives, and for values the caller builds.

 A value is one of the 17 kinds of the D-Bus type system. Its `sig` is the
 complete type signature of that value ("i", "a{sv}", "(su)", "v"), kept on the
 value itself so that empty arrays and variants still know their type. Strings
 are validated when a value is built, so a `Value` always holds valid UTF-8,
 object paths and signatures.

 Every value that holds memory (text, items, signatures) is allocated from the
 allocator passed to its constructor. Free that allocator (for example the
 arena of a received message) and the whole tree goes with it.

 Typed accessors look through VARIANT, so `dict_get("Name")?.as_string()` works
 on an `a{sv}` directly without unwrapping the variant by hand.
*>
module bleu::dbus::value;
import bleu::error, bleu::dbus::signature, bleu::dbus::names;

<*
 The kinds of value. Names follow the specification; the ordinal is internal
 and is not a wire code (use `Value.sig` for the code).
*>
enum Kind : char
{
	BYTE,
	BOOLEAN,
	INT16,
	UINT16,
	INT32,
	UINT32,
	INT64,
	UINT64,
	DOUBLE,
	STRING,
	OBJECT_PATH,
	SIGNATURE,
	UNIX_FD,
	ARRAY,
	STRUCT,
	DICT_ENTRY,
	VARIANT,
}

<*
 A value in the D-Bus type system.

 - `bits` carries integers, BOOLEAN (0 or 1), the bit pattern of a DOUBLE, and
 the index of a UNIX_FD in the message's descriptor array.
 - `text` carries STRING, OBJECT_PATH and SIGNATURE.
 - `items` carries the elements of an ARRAY, the fields of a STRUCT, the
 key and value of a DICT_ENTRY, and the single contents of a VARIANT.
*>
struct Value
{
	Kind kind;
	String sig;
	ulong bits;
	String text;
	Value[] items;
}

<* Boolean value (`b`). *>
fn Value boolean(bool v) @inline => { .kind = BOOLEAN, .sig = "b", .bits = v ? 1 : 0 };

<* Byte value (`y`). *>
fn Value byte_value(char v) @inline => { .kind = BYTE, .sig = "y", .bits = v };

<* 16-bit signed integer (`n`). *>
fn Value i16(short v) @inline => { .kind = INT16, .sig = "n", .bits = (ulong)(long)v };

<* 16-bit unsigned integer (`q`). *>
fn Value u16(ushort v) @inline => { .kind = UINT16, .sig = "q", .bits = v };

<* 32-bit signed integer (`i`). *>
fn Value i32(int v) @inline => { .kind = INT32, .sig = "i", .bits = (ulong)(long)v };

<* 32-bit unsigned integer (`u`). *>
fn Value u32(uint v) @inline => { .kind = UINT32, .sig = "u", .bits = v };

<* 64-bit signed integer (`x`). *>
fn Value i64(long v) @inline => { .kind = INT64, .sig = "x", .bits = (ulong)v };

<* 64-bit unsigned integer (`t`). *>
fn Value u64(ulong v) @inline => { .kind = UINT64, .sig = "t", .bits = v };

<* IEEE 754 double (`d`). *>
fn Value float64(double v) @inline => { .kind = DOUBLE, .sig = "d", .bits = bitcast(v, ulong) };

<*
 Index into the descriptor array of the message that carries this value (`h`).
 The descriptor itself is owned by the message, not by the value.
*>
fn Value unix_fd(uint index) @inline => { .kind = UNIX_FD, .sig = "h", .bits = index };

<*
 STRING value, copied into `allocator`.

 @param text : "UTF-8 text without NUL bytes"
 @return? error::INVALID_ARGUMENT : "The text is not valid D-Bus string data"
*>
fn Value? str(Allocator allocator, String text)
{
	if (!names::is_utf8_text(text)) return error::INVALID_ARGUMENT~;
	return { .kind = STRING, .sig = "s", .text = text.copy(allocator) };
}

<*
 OBJECT_PATH value, copied into `allocator`.

 @return? error::INVALID_ARGUMENT : "The text is not a valid object path"
*>
fn Value? path(Allocator allocator, String text)
{
	if (!names::is_object_path(text)) return error::INVALID_ARGUMENT~;
	return { .kind = OBJECT_PATH, .sig = "o", .text = text.copy(allocator) };
}

<*
 SIGNATURE value, copied into `allocator`.

 @return? error::INVALID_ARGUMENT : "The text is not a valid signature"
*>
fn Value? sig(Allocator allocator, String text)
{
	if (!signature::valid(text)) return error::INVALID_ARGUMENT~;
	return { .kind = SIGNATURE, .sig = "g", .text = text.copy(allocator) };
}

<*
 VARIANT holding `inner`. The variant's own signature is "v"; the contents
 keep their type on the wire.

 @param inner : "Any value; it is referenced, not copied"
*>
fn Value variant(Allocator allocator, Value inner)
{
	Value[] items = alloc::new_array(allocator, Value, 1);
	items[0] = inner;
	return { .kind = VARIANT, .sig = "v", .items = items };
}

<*
 ARRAY of `items`, each of the single complete type `element_sig`.

 @param element_sig : "Element type, for example \"s\" or \"{sv}\""
 @param items : "Elements; each must have `sig == element_sig`; referenced, not copied"
 @return? error::INVALID_ARGUMENT : "An element type mismatch, or the array signature is invalid or too long"
*>
fn Value? array(Allocator allocator, String element_sig, Value[] items)
{
	if (!signature::is_element(element_sig)) return error::INVALID_ARGUMENT~;
	String full = string::format(allocator, "a%s", element_sig);
	if (!signature::valid(full)) return error::INVALID_ARGUMENT~;
	foreach (item : items)
	{
		if (item.sig != element_sig) return error::INVALID_ARGUMENT~;
	}
	return { .kind = ARRAY, .sig = full, .items = copy_items(allocator, items) };
}

<*
 STRUCT with `fields`, in order. A struct needs at least one field.

 @return? error::INVALID_ARGUMENT : "No fields, or the signature is too long"
*>
fn Value? structure(Allocator allocator, Value[] fields)
{
	if (fields.len == 0) return error::INVALID_ARGUMENT~;
	DString full;
	full.init(tmem);
	full.append_char('(');
	foreach (field : fields) full.append_string(field.sig);
	full.append_char(')');
	if (full.len() > signature::MAX_LENGTH) return error::INVALID_ARGUMENT~;
	return { .kind = STRUCT, .sig = full.copy_str(allocator), .items = copy_items(allocator, fields) };
}

<*
 DICT_ENTRY `key` => `value`. The key must be a basic type.

 @return? error::INVALID_ARGUMENT : "The key is a container type"
*>
fn Value? dict_entry(Allocator allocator, Value key, Value value)
{
	if (!signature::is_basic(key.sig[0]) || key.sig.len != 1) return error::INVALID_ARGUMENT~;
	String full = string::format(allocator, "{%s%s}", key.sig, value.sig);
	if (full.len > signature::MAX_LENGTH) return error::INVALID_ARGUMENT~;
	Value[] items = alloc::new_array(allocator, Value, 2);
	items[0] = key;
	items[1] = value;
	return { .kind = DICT_ENTRY, .sig = full, .items = items };
}

fn Value[] copy_items(Allocator allocator, Value[] items) @private
{
	Value[] copy = alloc::new_array(allocator, Value, items.len);
	foreach (i, item : items) copy[i] = item;
	return copy;
}

<*
 The value with any VARIANT wrappers removed.
*>
fn Value Value.unwrap(self)
{
	Value v = self;
	while (v.kind == VARIANT) v = v.items[0];
	return v;
}

<* True when this value (after unwrapping variants) has `kind`. *>
fn bool Value.is(self, Kind kind) @inline => self.unwrap().kind == kind;

<*
 The text of a STRING value.

 @return? TYPE_MISMATCH : "The value is not a string"
*>
fn String? Value.as_string(self)
{
	Value v = self.unwrap();
	if (v.kind != STRING) return TYPE_MISMATCH~;
	return v.text;
}

<* The text of an OBJECT_PATH value. @return? TYPE_MISMATCH : "The value is not an object path" *>
fn String? Value.as_object_path(self)
{
	Value v = self.unwrap();
	if (v.kind != OBJECT_PATH) return TYPE_MISMATCH~;
	return v.text;
}

<* The text of a SIGNATURE value. @return? TYPE_MISMATCH : "The value is not a signature" *>
fn String? Value.as_signature(self)
{
	Value v = self.unwrap();
	if (v.kind != SIGNATURE) return TYPE_MISMATCH~;
	return v.text;
}

<* The value of a BOOLEAN. @return? TYPE_MISMATCH : "The value is not a boolean" *>
fn bool? Value.as_bool(self)
{
	Value v = self.unwrap();
	if (v.kind != BOOLEAN) return TYPE_MISMATCH~;
	return v.bits != 0;
}

<* The value of a BYTE. @return? TYPE_MISMATCH : "The value is not a byte" *>
fn char? Value.as_byte(self)
{
	Value v = self.unwrap();
	if (v.kind != BYTE) return TYPE_MISMATCH~;
	return (char)v.bits;
}

<* The value of an INT16. @return? TYPE_MISMATCH : "The value is not an int16" *>
fn short? Value.as_i16(self)
{
	Value v = self.unwrap();
	if (v.kind != INT16) return TYPE_MISMATCH~;
	return (short)(long)v.bits;
}

<* The value of a UINT16. @return? TYPE_MISMATCH : "The value is not a uint16" *>
fn ushort? Value.as_u16(self)
{
	Value v = self.unwrap();
	if (v.kind != UINT16) return TYPE_MISMATCH~;
	return (ushort)v.bits;
}

<* The value of an INT32. @return? TYPE_MISMATCH : "The value is not an int32" *>
fn int? Value.as_i32(self)
{
	Value v = self.unwrap();
	if (v.kind != INT32) return TYPE_MISMATCH~;
	return (int)(long)v.bits;
}

<* The value of a UINT32. @return? TYPE_MISMATCH : "The value is not a uint32" *>
fn uint? Value.as_u32(self)
{
	Value v = self.unwrap();
	if (v.kind != UINT32) return TYPE_MISMATCH~;
	return (uint)v.bits;
}

<* The value of an INT64. @return? TYPE_MISMATCH : "The value is not an int64" *>
fn long? Value.as_i64(self)
{
	Value v = self.unwrap();
	if (v.kind != INT64) return TYPE_MISMATCH~;
	return (long)v.bits;
}

<* The value of a UINT64. @return? TYPE_MISMATCH : "The value is not a uint64" *>
fn ulong? Value.as_u64(self)
{
	Value v = self.unwrap();
	if (v.kind != UINT64) return TYPE_MISMATCH~;
	return v.bits;
}

<* The value of a DOUBLE. @return? TYPE_MISMATCH : "The value is not a double" *>
fn double? Value.as_f64(self)
{
	Value v = self.unwrap();
	if (v.kind != DOUBLE) return TYPE_MISMATCH~;
	return bitcast(v.bits, double);
}

<*
 The descriptor index of a UNIX_FD value.

 @return? TYPE_MISMATCH : "The value is not a file descriptor"
*>
fn uint? Value.as_unix_fd(self)
{
	Value v = self.unwrap();
	if (v.kind != UNIX_FD) return TYPE_MISMATCH~;
	return (uint)v.bits;
}

<* Number of elements (ARRAY), fields (STRUCT), or 2 for a DICT_ENTRY; 0 otherwise. *>
fn usz Value.count(self) => self.unwrap().items.len;

<*
 Element `index` of an array or field `index` of a struct.

 @return? NOT_FOUND : "The index is past the end, or the value is not a container"
*>
fn Value? Value.at(self, usz index)
{
	Value v = self.unwrap();
	if (v.kind != ARRAY && v.kind != STRUCT) return NOT_FOUND~;
	if (index >= v.items.len) return NOT_FOUND~;
	return v.items[index];
}

<*
 The value stored under `key` in a dictionary (an ARRAY of DICT_ENTRY, such as
 an `a{sv}`). String-like keys are compared by text. The value is returned as
 stored: for `a{sv}` it is a VARIANT, which the typed accessors look through.

 @return? NOT_FOUND : "No entry has this key, or the value is not a dictionary"
*>
fn Value? Value.dict_get(self, String key)
{
	Value v = self.unwrap();
	if (v.kind != ARRAY || v.sig.len < 2 || v.sig[1] != '{') return NOT_FOUND~;
	foreach (entry : v.items)
	{
		Value k = entry.items[0];
		if (k.kind == STRING || k.kind == OBJECT_PATH || k.kind == SIGNATURE)
		{
			if (k.text == key) return entry.items[1];
		}
	}
	return NOT_FOUND~;
}