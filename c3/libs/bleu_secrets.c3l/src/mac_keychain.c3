<*
 macOS keychain declarations: the Security framework's generic-password API and
 the CoreFoundation dictionary calls it needs.

 Sources: Security item functions (security-framework-sys-2.14.0 src/keychain_item.rs
 lines 12-21: SecItemAdd, SecItemCopyMatching, SecItemUpdate, SecItemDelete);
 constants (security-framework-sys-2.14.0 src/item.rs: kSecClass line 4,
 kSecClassGenericPassword line 6, kSecMatchLimit 11, kSecMatchLimitAll 12,
 kSecReturnData 19, kSecReturnAttributes 20, kSecAttrLabel 28, kSecAttrComment 81,
 kSecAttrService 88, kSecAttrAccount 90, kSecValueData 91); CFDictionaryCreate and
 the callback structs (core-foundation-sys-0.8.7 src/dictionary.rs lines 29-36 and 59-61).

 Deliberately the legacy login keychain: no kSecUseDataProtectionKeychain (that
 needs a signed, entitled app). Compiled only; nothing here has run on macOS.
*>
module bleu::secrets::keychain @feat(DARWIN) @link("Security.framework");
import bleu::cf;

extern fn int sec_item_add(cf::CFTypeRef attributes, cf::CFTypeRef* result) @cname("SecItemAdd");
extern fn int sec_item_copy_matching(cf::CFTypeRef query, cf::CFTypeRef* result) @cname("SecItemCopyMatching");
extern fn int sec_item_update(cf::CFTypeRef query, cf::CFTypeRef changes) @cname("SecItemUpdate");
extern fn int sec_item_delete(cf::CFTypeRef query) @cname("SecItemDelete");

extern const cf::CFTypeRef KSEC_CLASS @cname("kSecClass");
extern const cf::CFTypeRef KSEC_CLASS_GENERIC_PASSWORD @cname("kSecClassGenericPassword");
extern const cf::CFTypeRef KSEC_ATTR_SERVICE @cname("kSecAttrService");
extern const cf::CFTypeRef KSEC_ATTR_ACCOUNT @cname("kSecAttrAccount");
extern const cf::CFTypeRef KSEC_ATTR_LABEL @cname("kSecAttrLabel");
extern const cf::CFTypeRef KSEC_ATTR_COMMENT @cname("kSecAttrComment");
extern const cf::CFTypeRef KSEC_VALUE_DATA @cname("kSecValueData");
extern const cf::CFTypeRef KSEC_RETURN_DATA @cname("kSecReturnData");
extern const cf::CFTypeRef KSEC_RETURN_ATTRIBUTES @cname("kSecReturnAttributes");
extern const cf::CFTypeRef KSEC_MATCH_LIMIT @cname("kSecMatchLimit");
extern const cf::CFTypeRef KSEC_MATCH_LIMIT_ALL @cname("kSecMatchLimitAll");

<* CFDictionaryKeyCallBacks (six pointer-sized members). *>
struct KeyCallbacks
{
	cf::CFIndex version;
	void* retain;
	void* release;
	void* copy_description;
	void* equal;
	void* hash;
}

<* CFDictionaryValueCallBacks (five pointer-sized members). *>
struct ValueCallbacks
{
	cf::CFIndex version;
	void* retain;
	void* release;
	void* copy_description;
	void* equal;
}

extern const KeyCallbacks KCF_TYPE_DICTIONARY_KEY_CALLBACKS @cname("kCFTypeDictionaryKeyCallBacks");
extern const ValueCallbacks KCF_TYPE_DICTIONARY_VALUE_CALLBACKS @cname("kCFTypeDictionaryValueCallBacks");
extern fn cf::CFTypeRef cf_dictionary_create(
	cf::CFTypeRef allocator,
	cf::CFTypeRef* keys,
	cf::CFTypeRef* values,
	cf::CFIndex count,
	KeyCallbacks* key_callbacks,
	ValueCallbacks* value_callbacks
) @cname("CFDictionaryCreate");

<* A dictionary from parallel key and value arrays. Owned by the caller. *>
fn cf::Ref dictionary(cf::CFTypeRef[] keys, cf::CFTypeRef[] values)
{
	return cf::adopt(
		cf_dictionary_create(
			null,
			keys.ptr,
			values.ptr,
			(cf::CFIndex)keys.len,
			&KCF_TYPE_DICTIONARY_KEY_CALLBACKS,
			&KCF_TYPE_DICTIONARY_VALUE_CALLBACKS
		)
	);
}