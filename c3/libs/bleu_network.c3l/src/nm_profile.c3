// Saved Wi-Fi profiles (NetworkManager "connections") as the backend sees them.
// Read on demand, not cached: a shell has a handful of profiles, and a cache
// would have to follow every add, change and removal done by other programs.
module bleu::network::networkmanager @feat(LINUX);
import std::collections::list, bleu::error, bleu::dbus::connection, bleu::dbus::proxy, bleu::dbus::value, bleu::network, bleu::network::nm_settings;

<* A saved Wi-Fi profile: its object path, its network and its autoconnect flag. *>
struct Profile
{
	String path;
	String uuid;
	char[] ssid;
	bool autoconnect;
}

<*
 Every saved Wi-Fi profile, read from NetworkManager's settings service.
 Strings and octets are copied into `allocator`.

 @return? error::DISCONNECTED : "The bus closed"
*>
fn Profile[]? load_profiles(Connection* bus, Allocator allocator)
{
	Proxy settings = object_proxy(bus, NM_SETTINGS_PATH, NM_SETTINGS_IFACE)!;
	@pool()
	{
		Value paths = method_value(&settings, "ListConnections", tmem)!;
		List{Profile} found;
		found.init(allocator);
		for (usz i = 0; i < paths.count(); i++)
		{
			String path = paths.at(i)!.as_object_path()!;
			Proxy connection = object_proxy(bus, path, NM_CONNECTION_IFACE)!;
			Value current = method_value(&connection, "GetSettings", tmem)!;
			Value wireless;
			Value general;
			if (try w = current.dict_get(nm_settings::GROUP_WIRELESS)) { wireless = w; } else { continue; }
			if (try g = current.dict_get(nm_settings::GROUP_CONNECTION)) { general = g; } else { continue; }
			char[] ssid = bytes_of(allocator, wireless, "ssid");
			if (ssid.len == 0) continue;
			found.push({
				.path = path.copy(allocator),
				.uuid = text_of(allocator, general, "uuid"),
				.ssid = ssid,
				.autoconnect = bool_or(general, "autoconnect", true),
			});
		}
		return found.array_view();
	};
}

<* The profile for this SSID, or NOT_FOUND. *>
fn Profile? find_profile(Profile[] profiles, char[] ssid)
{
	foreach (profile : profiles)
	{
		if (network::same_ssid(profile.ssid, ssid)) return profile;
	}
	return NOT_FOUND~;
}
