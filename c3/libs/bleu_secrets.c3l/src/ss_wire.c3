<*
 The Secret Service wire vocabulary: names, the `Secret` struct, and the
 attribute and property keys. Pure data and marshalling, with no bus.

 Source: Secret Service API draft (https://specifications.freedesktop.org/secret-service/latest/):
 Service, Collection, Item, Session and Prompt interfaces (chapter 13), the
 Secret struct (chapter 14.1.1: session o, parameters ay, value ay, content_type s,
 signature "(oayays)"), and the item and collection properties. The names and
 the algorithm strings are also in secret-service-4.0.0/src/ss.rs.
*>
module bleu::secrets::ss;
import bleu::error, bleu::dbus::value, bleu::dbus::marshal;

<* The well-known name of the keyring daemon on the session bus. *>
const BUS_NAME             = "org.freedesktop.secrets";
<* The service object. *>
const SERVICE_PATH         = "/org/freedesktop/secrets";
const SERVICE_INTERFACE    = "org.freedesktop.Secret.Service";
const COLLECTION_INTERFACE = "org.freedesktop.Secret.Collection";
const ITEM_INTERFACE       = "org.freedesktop.Secret.Item";
const SESSION_INTERFACE    = "org.freedesktop.Secret.Session";
const PROMPT_INTERFACE     = "org.freedesktop.Secret.Prompt";

<* The alias of the default collection. *>
const DEFAULT_ALIAS   = "default";
<* The object path that means "none" in replies (no prompt, no collection). *>
const NO_OBJECT       = "/";
<* Session algorithm names, as the OpenSession method takes them. *>
const ALGORITHM_PLAIN = "plain";
const ALGORITHM_DH    = "dh-ietf1024-sha256-aes128-cbc-pkcs7";

<* Property names of collections and items. *>
const COLLECTION_LABEL  = "org.freedesktop.Secret.Collection.Label";
const ITEM_LABEL        = "org.freedesktop.Secret.Item.Label";
const ITEM_ATTRIBUTES   = "org.freedesktop.Secret.Item.Attributes";
const PROPERTY_LOCKED   = "Locked";
const PROPERTY_CREATED  = "Created";
const PROPERTY_MODIFIED = "Modified";

<* The attribute every item this library writes carries: marks it as ours. *>
const OWNER_KEY   = "bleu.owner";
const OWNER_VALUE = "bleu";
<* Attributes naming the entry. Lookups filter on them. *>
const SERVICE_KEY = "bleu.service";
const ACCOUNT_KEY = "bleu.account";

<* The content type recorded with each secret. *>
const CONTENT_TYPE = "text/plain; charset=utf8";

<*
 One `Secret` struct. `parameters` is the AES IV for an encrypted session and
 empty for `plain`; `value` is the (possibly encrypted) secret.
*>
struct WireSecret
{
	String session;
	char[] parameters;
	char[] value;
	String content_type;
}

<*
 Write a `Secret` as the signature "(oayays)". The writer must be at a point
 where a struct value is expected.
*>
fn void? write_secret(Writer* w, WireSecret secret)
{
	w.begin_struct()!;
	w.append_object_path(secret.session)!;
	write_bytes(w, secret.parameters)!;
	write_bytes(w, secret.value)!;
	w.append_string(secret.content_type)!;
	w.end_struct()!;
}

<* Write `bytes` as an array of bytes ("ay"). *>
fn void? write_bytes(Writer* w, char[] bytes)
{
	w.begin_array("ay")!;
	foreach (b : bytes) w.append_byte(b)!;
	w.end_array()!;
}

<*
 Read a `Secret` struct from a decoded value. The fields are copied into
 `allocator`, so the value may be released afterwards.

 @return? error::PROTOCOL : "The value is not a Secret struct"
*>
fn WireSecret? read_secret(Value v, Allocator allocator)
{
	Value fields = v.unwrap();
	if (fields.kind != STRUCT || fields.count() != 4) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"a Secret has four fields"
	)~;
	String session      = fields.at(0)!.as_object_path()!;
	char[] parameters   = bytes_of(fields.at(1)!, allocator)!;
	char[] content      = bytes_of(fields.at(2)!, allocator)!;
	String content_type = fields.at(3)!.as_string()!;
	return {
		.session = session.copy(allocator),
		.parameters = parameters,
		.value = content,
		.content_type = content_type.copy(allocator)
	};
}

<* The bytes of an array-of-byte value, copied into `allocator`. *>
fn char[]? bytes_of(Value array, Allocator allocator)
{
	Value items = array.unwrap();
	if (items.kind != ARRAY) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"expected an array of bytes"
	)~;
	char[] out = alloc::alloc_array(allocator, char, (sz)items.count());
	for (usz i = 0; i < items.count(); i++) out[i] = items.at(i)!.as_byte()!;
	return out;
}