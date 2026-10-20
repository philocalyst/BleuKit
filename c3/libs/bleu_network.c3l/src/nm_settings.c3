<*
 NetworkManager connection settings (`a{sa{sv}}`) for Wi-Fi profiles, built as
 D-Bus values. Pure: nothing is sent here.

 Key names follow the NetworkManager settings specification
 (https://networkmanager.dev/docs/api/latest/settings-802-11-wireless.html,
 settings-802-11-wireless-security.html, settings-connection.html). The
 key-management strings ("wpa-psk", "sae", "owe") are the ones NetworkManager's
 own client library sends (nmrs 3.5.6, src/api/builders/wifi_builder.rs).
*>
module bleu::network::nm_settings;
import std::collections::list, std::hash::sha256, bleu::error, bleu::dbus::value, bleu::network;

const String GROUP_CONNECTION = "connection";
const String GROUP_WIRELESS   = "802-11-wireless";
const String GROUP_SECURITY   = "802-11-wireless-security";
const String TYPE_WIRELESS    = "802-11-wireless";
const String MODE_INFRA       = "infrastructure";
const String HEX_DIGITS       = "0123456789abcdef";
const usz UUID_OCTETS         = 16; // a UUID is 128 bits
const char UUID_VERSION_8     = 0x80; // RFC 9562 version nibble 8 (the high nibble of octet 6)
const char UUID_VARIANT_RFC   = 0x80; // RFC 4122 variant: bits 10 in the high bits of octet 8

<* How a profile authenticates. `OPEN` writes no security group at all. *>
enum KeyManagement : char
{
	OPEN,
	WPA_PSK,
	SAE,
	OWE,
}

<* What a Wi-Fi profile holds. `psk` is used only for WPA_PSK and SAE. *>
struct ProfileSpec
{
	char[] ssid;
	String id;
	String uuid;
	bool autoconnect;
	KeyManagement key_mgmt;
	String psk;
}

<*
 The connection settings for a Wi-Fi profile, as an `a{sa{sv}}`.

 @param allocator : "Allocator for the returned value"
 @return? error::INVALID_ARGUMENT : "A value could not be encoded"
*>
fn Value? profile_settings(Allocator allocator, ProfileSpec spec)
{
	Value[] connection = {
		kv(allocator, "id", value::str(allocator, spec.id)!!),
		kv(allocator, "uuid", value::str(allocator, spec.uuid)!!),
		kv(allocator, "type", value::str(allocator, TYPE_WIRELESS)!!),
		kv(allocator, "autoconnect", value::boolean(spec.autoconnect)),
	};
	Value[] wireless = {
		kv(allocator, "ssid", bytes_value(allocator, spec.ssid)),
		kv(allocator, "mode", value::str(allocator, MODE_INFRA)!!),
	};
	List{Value} groups;
	groups.init(tmem);
	groups.push(group(allocator, GROUP_CONNECTION, connection));
	groups.push(group(allocator, GROUP_WIRELESS, wireless));
	if (spec.key_mgmt != OPEN)
	{
		List{Value} security;
		security.init(tmem);
		security.push(kv(allocator, "key-mgmt", value::str(allocator, key_mgmt_name(spec.key_mgmt))!!));
		// No passphrase: the psk key is left out, so NetworkManager asks its secret agent for it.
		if ((spec.key_mgmt == WPA_PSK || spec.key_mgmt == SAE) && spec.psk.len > 0)
		{
			security.push(kv(allocator, "psk", value::str(allocator, spec.psk)!!));
		}
		groups.push(group(allocator, GROUP_SECURITY, security.array_view()));
	}
	return value::array(allocator, "{sa{sv}}", groups.array_view());
}

<*
 The secrets an agent answers NetworkManager's GetSecrets with: the passphrase,
 as an `a{sa{sv}}` holding only the security group.

 @param allocator : "Allocator for the returned value"
 @return? error::INVALID_ARGUMENT : "A value could not be encoded"
*>
fn Value? secrets_settings(Allocator allocator, String psk)
{
	Value[] fields = { kv(allocator, "psk", value::str(allocator, psk)!!) };
	Value[] groups = { group(allocator, GROUP_SECURITY, fields) };
	return value::array(allocator, "{sa{sv}}", groups);
}

<* The NetworkManager `key-mgmt` string for a key-management kind; "none" for open networks. *>
fn String key_mgmt_name(KeyManagement key_mgmt)
{
	switch (key_mgmt)
	{
		case OPEN: return "none";
		case WPA_PSK: return "wpa-psk";
		case SAE: return "sae";
		case OWE: return "owe";
	}
}

<*
 A UUID for a Wi-Fi profile, derived from the SSID octets with SHA-256 (std::hash::sha256).
 It is stable for a network, so the same network always gets the same UUID, and two
 networks collide only if their SHA-256 digests agree in 128 bits: a second preimage
 that cannot be found on purpose. The layout is RFC 9562's custom UUID (version 8) with
 the RFC 4122 variant bits. NetworkManager needs uniqueness per profile, which this gives.
*>
fn String uuid_for_ssid(Allocator allocator, char[] ssid)
{
	char[sha256::HASH_SIZE] digest = sha256::hash(ssid);
	digest[6] = (digest[6] & 0x0F) | UUID_VERSION_8;
	digest[8] = (digest[8] & 0x3F) | UUID_VARIANT_RFC;
	char[36] text;
	usz at = 0;
	for (usz i = 0; i < UUID_OCTETS; i++)
	{
		if (i == 4 || i == 6 || i == 8 || i == 10) text[at++] = '-';
		text[at++] = HEX_DIGITS[((char)digest[i] >> 4) & 0xF];
		text[at++] = HEX_DIGITS[(char)digest[i] & 0xF];
	}
	return ((String)text[..]).copy(allocator);
}

<*
 A copy of the dictionary `dict` with `key` set to `new_value`. For an `a{sv}`
 the value is a variant; for an `a{sa{sv}}` it is the inner `a{sv}`.

 @return? error::INVALID_ARGUMENT : "`dict` is not a dictionary"
*>
fn Value? dict_with(Allocator allocator, Value dict, String key, Value new_value)
{
	if (dict.sig.len < 4 || dict.sig[0] != 'a' || dict.sig[1] != '{') return error::INVALID_ARGUMENT~;
	List{Value} entries;
	entries.init(tmem);
	foreach (entry : dict.items)
	{
		if (try name = entry.items[0].as_string())
		{
			if (name == key) continue;
		}
		entries.push(entry);
	}
	entries.push(value::dict_entry(allocator, value::str(allocator, key)!!, new_value)!!);
	return value::array(allocator, dict.sig[1:dict.sig.len - 1], entries.array_view());
}

<*
 A copy of `settings` with `group.key` set to a boolean. The group is created
 when it does not exist yet.

 @return? error::INVALID_ARGUMENT : "`settings` is not an `a{sa{sv}}`"
*>
fn Value? with_bool(Allocator allocator, Value settings, String group_name, String key, bool flag)
{
	Value current;
	if (try found = settings.dict_get(group_name))
	{
		current = found;
	}
	else
	{
		Value[] none = { };
		current = value::array(allocator, "{sv}", none)!!;
	}
	Value updated = dict_with(allocator, current, key, value::variant(allocator, value::boolean(flag)))!;
	return dict_with(allocator, settings, group_name, updated);
}

<*
 A copy of `settings` with the Wi-Fi secret replaced: `key-mgmt` and, for WPA-PSK and
 SAE, `psk` of the `802-11-wireless-security` group. Every other key, group and the
 connection's id, UUID and autoconnect flag are kept, so a saved profile keeps its
 addresses, DNS, MTU and metered setting. The group is created when it does not exist.

 @return? error::INVALID_ARGUMENT : "`settings` is not an `a{sa{sv}}`"
*>
fn Value? with_secret(Allocator allocator, Value settings, KeyManagement key_mgmt, String psk)
{
	Value current;
	if (try found = settings.dict_get(GROUP_SECURITY))
	{
		current = found;
	}
	else
	{
		Value[] none = { };
		current = value::array(allocator, "{sv}", none)!!;
	}
	Value updated = dict_with(
		allocator,
		current,
		"key-mgmt",
		value::variant(allocator, value::str(allocator, key_mgmt_name(key_mgmt))!!)
	)!;
	if ((key_mgmt == WPA_PSK || key_mgmt == SAE) && psk.len > 0)
	{
		updated = dict_with(allocator, updated, "psk", value::variant(allocator, value::str(allocator, psk)!!))!;
	}
	return dict_with(allocator, settings, GROUP_SECURITY, updated);
}

<*
 Octets of an `ay` value, possibly wrapped in a variant, copied into `allocator`.

 @return? error::INVALID_ARGUMENT : "The value is not an array of bytes"
*>
fn char[]? bytes_from(Allocator allocator, Value bytes)
{
	Value array = bytes.unwrap();
	if (array.sig != "ay") return error::INVALID_ARGUMENT~;
	char[] out = alloc::new_array(allocator, char, (sz)array.count());
	for (usz i = 0; i < out.len; i++)
	{
		out[i] = array.at(i)!!.as_byte()!!;
	}
	return out;
}

// `{key: value}` for an `a{sv}`: the value is wrapped in a variant.
fn Value kv(Allocator allocator, String key, Value inner) @local
{
	return value::dict_entry(allocator, value::str(allocator, key)!!, value::variant(allocator, inner))!!;
}

// `{name: {fields}}` for an `a{sa{sv}}`: the inner dictionary is an `a{sv}`, not a variant.
fn Value group(Allocator allocator, String name, Value[] fields) @local
{
	Value dict = value::array(allocator, "{sv}", fields)!!;
	return value::dict_entry(allocator, value::str(allocator, name)!!, dict)!!;
}

fn Value bytes_value(Allocator allocator, char[] bytes) @local
{
	Value[] items = alloc::new_array(allocator, Value, bytes.len);
	foreach (i, b : bytes) items[i] = value::byte_value(b);
	return value::array(allocator, "y", items)!!;
}