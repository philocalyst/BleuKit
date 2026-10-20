<*
 IIDs of parameterized WinRT interfaces and delegates, such as
 `IAsyncOperation<bool>` or `IVectorView<HSTRING>`.

 Those IIDs are not constants in any header. The WinRT type system defines
 them as a name-based (version 5, RFC 4122 section 4.3) UUID over a signature
 string that spells the type, so a Bleu program derives them at run time. The
 algorithm and grammar are from Microsoft Learn, "WinRT type system", section
 "Guid generation for parameterized types"
 (https://learn.microsoft.com/en-us/uwp/winrt-cref/winrt-type-system), and it
 reproduces the MIDL-generated IIDs in mingw-w64 `windows.foundation.h`
 (see docs/research/bleu_win.md, section 5).

 Pure logic: no Win32 import, unit-tested on every host.
*>
module bleu::win::pinterface;
import std::hash::sha1, std::core::string;
import bleu::win::guid;

<*
 The namespace GUID of the WinRT parameterized-type algorithm,
 `11f47ad5-7b73-42c0-abae-878b1e16adee` (WinRT type system doc, grammar section).
*>
const Guid WINRT_NAMESPACE = guid::guid("11f47ad5-7b73-42c0-abae-878b1e16adee");

<* Signature of the base type `Boolean`. *>
const String SIG_BOOL = "b1";
<* Signature of `UInt8`. *>
const String SIG_U8 = "u1";
<* Signature of `Int32`. *>
const String SIG_I32 = "i4";
<* Signature of `UInt32`. *>
const String SIG_U32 = "u4";
<* Signature of `Int64`. *>
const String SIG_I64 = "i8";
<* Signature of `UInt64`. *>
const String SIG_U64 = "u8";
<* Signature of `Single`. *>
const String SIG_F32 = "f4";
<* Signature of `Double`. *>
const String SIG_F64 = "f8";
<* Signature of `Char16`. *>
const String SIG_CHAR16 = "c2";
<* Signature of `String`, which is HSTRING on the ABI. *>
const String SIG_STRING = "string";
<* Signature of `Guid`. *>
const String SIG_GUID = "g16";
<* Signature of `IInspectable` as an object type argument. *>
const String SIG_IINSPECTABLE = "cinterface(IInspectable)";

<*
 PIIDs (parameterized interface IDs) of the generic types this library uses,
 as the `windows` crate's generated bindings spell them (windows-future 0.100.0
 `src/bindings.rs`, windows-collections 0.100.0 `src/bindings.rs`). The test
 vectors in pinterface_test.c3 check them end to end against the IIDs of the
 MIDL-generated Windows SDK header.
*>
const Guid PIID_ASYNC_OPERATION = guid::guid("9fc2b0bb-e446-44e2-aa61-9cab8f636af2");
const Guid PIID_ASYNC_OPERATION_COMPLETED = guid::guid("fcdcf02c-e5d8-4478-915a-4d90b74b83a5");
const Guid PIID_VECTOR_VIEW = guid::guid("bbe1fa4c-b0e3-4583-baef-1f1b2e483e56");
const Guid PIID_ITERABLE = guid::guid("faa585ea-6214-4217-afda-7f46de5869b3");
const Guid PIID_REFERENCE = guid::guid("61c17706-2d65-11e0-9ae8-d48564015472");

<*
 The type signature of an interface that is not itself a parameterized
 instance: its IID in lower-case dashed form inside braces, for example
 `{00000000-0000-0000-c000-000000000046}`.

 @return "The signature, in temporary memory"
*>
fn String interface_signature(Guid iid) @inline => guid_braced_lower(iid);

<*
 The IID of the parameterized instance `piid<args>`.

 `args` is the already-joined list of argument signatures, separated by `;`:
 `instance(PIID_ASYNC_OPERATION, SIG_BOOL)` is `IAsyncOperation<Boolean>`.

 @param piid : "The PIID of the generic interface or delegate"
 @param args : "The argument signatures, separated by ';'"
 @return "The IID, computed by the WinRT name-based UUID algorithm"
*>
fn Guid instance(Guid piid, String args)
{
	String signature = string::tformat("pinterface(%s;%s)", guid_braced_lower(piid), args);
	return derive(signature);
}

<*
 Name-based version 5 UUID of `name` in the WinRT namespace: SHA-1 over the
 namespace's 16 network-order bytes followed by the UTF-8 name, then the
 version and variant bits set as RFC 4122 section 4.3 requires.

 Source: the same procedure in windows-core 0.62.2 `src/guid.rs`
 (`GUID::from_signature`) and the WinRT type system doc.

 @return "The derived GUID"
*>
fn Guid derive(String name)
{
	char[16] namespace_bytes = octets(WINRT_NAMESPACE);
	sha1::Sha1 sha @noinit;
	sha.init();
	sha.update(namespace_bytes[..]);
	sha.update(name);
	char[20] digest = sha.final();
	// Fields are read big-endian from the digest; the version nibble is 5 and the variant is RFC 4122.
	uint data1 = ((uint)digest[0] << 24) | ((uint)digest[1] << 16) | ((uint)digest[2] << 8) | (uint)digest[3];
	ushort data2 = (ushort)(((uint)digest[4] << 8) | (uint)digest[5]);
	ushort data3 = (ushort)(((((uint)digest[6] << 8) | (uint)digest[7]) & 0x0fff) | 0x5000);
	char[8] data4 = { (char)((digest[8] & 0x3f) | 0x80), digest[9], digest[10], digest[11],
	                  digest[12], digest[13], digest[14], digest[15] };
	return { .data1 = data1, .data2 = data2, .data3 = data3, .data4 = data4 };
}

<* The sixteen bytes of a GUID in network (RFC 4122) byte order. *>
fn char[16] octets(Guid g) @local
{
	return {
		(char)(g.data1 >> 24), (char)(g.data1 >> 16), (char)(g.data1 >> 8), (char)g.data1,
		(char)(g.data2 >> 8), (char)g.data2,
		(char)(g.data3 >> 8), (char)g.data3,
		g.data4[0], g.data4[1], g.data4[2], g.data4[3], g.data4[4], g.data4[5], g.data4[6], g.data4[7],
	};
}

<* `{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}` in lower case, as the grammar requires. *>
fn String guid_braced_lower(Guid g) @local
{
	return string::tformat("{%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x}",
		g.data1, g.data2, g.data3,
		g.data4[0], g.data4[1], g.data4[2], g.data4[3],
		g.data4[4], g.data4[5], g.data4[6], g.data4[7]);
}
