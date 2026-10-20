<*
 WLAN profile XML for `WlanSetProfile`, built as text. Pure: no Windows calls,
 so the builder and its tests run on every platform.

 Element names, their order and the words used (`authentication`, `encryption`,
 `keyType`) come from the WLAN profile schema: the AuthEncryption element
 (https://learn.microsoft.com/en-us/windows/win32/nativewifi/wlan-profileschema-authencryption-security-element)
 and the profile shape of rs-wifi 0.1.8 (src/profile.rs lines 17-232,
 https://static.crates.io/crates/rs-wifi/rs-wifi-0.1.8.crate). The namespace is
 the one Windows writes: http://www.microsoft.com/networking/WLAN/profile/v1.
 The tests check the element order and content; no XSD is on disk to validate
 against, so schema validation is not claimed.
*>
module bleu::network::wlan_profile;
import bleu::error, bleu::network;

const String PROFILE_NAMESPACE = "http://www.microsoft.com/networking/WLAN/profile/v1";
const String HEX_DIGITS        = "0123456789abcdef";

<* The `authentication` word for a security class, or NOT_FOUND for a class this backend cannot profile. *>
fn String? authentication_word(Security security)
{
	switch (security)
	{
		case OPEN: return "open";
		case WPA2_PSK: return "WPA2PSK";
		case WPA3_SAE: return "WPA3SAE";
		case OWE: return "OWE";
		default: return NOT_FOUND~;
	}
}

<*
 The profile name for an SSID: the SSID as text when it is UTF-8, otherwise
 "bleu-" and the hex of its octets, so every SSID has a name Windows accepts.
*>
fn String profile_name(Allocator allocator, char[] ssid)
{
	Ssid named = network::make_ssid(tmem, ssid);
	if (named.label.len > 0) return named.label.copy(allocator);
	DString name;
	name.init(tmem);
	name.append_string("bleu-");
	append_hex(&name, ssid);
	return name.copy_str(allocator);
}

// Appends the lowercase hex of `octets`.
fn void append_hex(DString* out, char[] octets) @local
{
	foreach (c : octets)
	{
		out.append_char(HEX_DIGITS[((char)c >> 4) & 0xF]);
		out.append_char(HEX_DIGITS[(char)c & 0xF]);
	}
}

// Appends `text` with the XML special characters escaped.
fn void append_escaped(DString* out, String text) @local
{
	foreach (c : text)
	{
		switch (c)
		{
			case '&': out.append_string("&amp;");
			case '<': out.append_string("&lt;");
			case '>': out.append_string("&gt;");
			case '"': out.append_string("&quot;");
			case '\'': out.append_string("&apos;");
			default: out.append_char(c);
		}
	}
}

<*
 The XML of a profile for an SSID with a security class. `passphrase` is
 required for WPA2_PSK and WPA3_SAE and ignored for open and OWE networks.

 @param allocator : "Allocator for the returned text"
 @return? error::UNSUPPORTED : "This backend cannot write a profile for the security class"
 @return? error::INVALID_ARGUMENT : "The security class needs a passphrase and none was given"
*>
fn String? profile_xml(Allocator allocator, char[] ssid, Security security, String passphrase, bool autoconnect)
{
	String? authentication = authentication_word(security);
	if (catch err = authentication) return error::UNSUPPORTED~;
	bool keyed = security == WPA2_PSK || security == WPA3_SAE;
	if (keyed && passphrase.len == 0) return error::INVALID_ARGUMENT~;
	String encryption = security == OPEN ? "none" : "AES";
	Ssid named        = network::make_ssid(tmem, ssid);
	DString out;
	out.init(tmem);
	out.append_string("<?xml version=\"1.0\"?>\n");
	out.appendf("<WLANProfile xmlns=\"%s\">\n", PROFILE_NAMESPACE);
	out.append_string("\t<name>");
	append_escaped(&out, profile_name(tmem, ssid));
	out.append_string("</name>\n");
	out.append_string("\t<SSIDConfig>\n\t\t<SSID>\n\t\t\t<hex>");
	append_hex(&out, ssid);
	out.append_string("</hex>\n");
	if (named.label.len > 0)
	{
		out.append_string("\t\t\t<name>");
		append_escaped(&out, named.label);
		out.append_string("</name>\n");
	}
	out.append_string("\t\t</SSID>\n\t</SSIDConfig>\n");
	out.append_string("\t<connectionType>ESS</connectionType>\n");
	out.appendf("\t<connectionMode>%s</connectionMode>\n", autoconnect ? "auto" : "manual");
	out.append_string("\t<MSM>\n\t\t<security>\n\t\t\t<authEncryption>\n");
	out.appendf("\t\t\t\t<authentication>%s</authentication>\n", authentication);
	out.appendf("\t\t\t\t<encryption>%s</encryption>\n", encryption);
	out.append_string("\t\t\t\t<useOneX>false</useOneX>\n\t\t\t</authEncryption>\n");
	if (keyed)
	{
		out.append_string(
			"\t\t\t<sharedKey>\n\t\t\t\t<keyType>passPhrase</keyType>\n\t\t\t\t<protected>false</protected>\n\t\t\t\t<keyMaterial>"
		);
		append_escaped(&out, passphrase);
		out.append_string("</keyMaterial>\n\t\t\t</sharedKey>\n");
	}
	out.append_string("\t\t</security>\n\t</MSM>\n</WLANProfile>\n");
	return out.copy_str(allocator);
}