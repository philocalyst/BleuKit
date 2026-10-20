// Small D-Bus helpers for the NetworkManager backend: typed property reads and
// method calls. Every value a helper returns is copied into the allocator the
// caller names, because replies are released as soon as the helper returns.
module bleu::network::networkmanager @feat(LINUX);
import std::time, bleu::error, bleu::dbus::connection, bleu::dbus::proxy, bleu::dbus::message, bleu::dbus::value, bleu::network::nm_settings;

const String NM_SERVICE          = "org.freedesktop.NetworkManager";
const String NM_PATH             = "/org/freedesktop/NetworkManager";
const String NM_DEVICES_PATH     = "/org/freedesktop/NetworkManager/Devices";
const String NM_SETTINGS_PATH    = "/org/freedesktop/NetworkManager/Settings";
const String NM_IFACE            = "org.freedesktop.NetworkManager";
const String NM_DEVICE_IFACE     = "org.freedesktop.NetworkManager.Device";
const String NM_WIRELESS_IFACE   = "org.freedesktop.NetworkManager.Device.Wireless";
const String NM_AP_IFACE         = "org.freedesktop.NetworkManager.AccessPoint";
const String NM_SETTINGS_IFACE   = "org.freedesktop.NetworkManager.Settings";
const String NM_CONNECTION_IFACE = "org.freedesktop.NetworkManager.Settings.Connection";
const String NM_ACTIVE_IFACE     = "org.freedesktop.NetworkManager.Connection.Active";
const String NO_OBJECT           = "/";

<* The unwrapped value of a numeric or boolean property, or its default when absent. *>
fn uint uint_of(Value props, String key)
{
	if (try v = props.dict_get(key))
	{
		if (try n = v.as_u32()) return n;
	}
	return 0;
}

<* A `y` (byte) property as a number, or 0 when absent. *>
fn uint byte_of(Value props, String key)
{
	if (try v = props.dict_get(key))
	{
		if (try b = v.as_byte()) return (uint)(char)b;
	}
	return 0;
}

<* The reason of a `(uu)` StateReason property (state, reason); 0 when absent. *>
fn uint reason_of(Value props, String key)
{
	if (try v = props.dict_get(key))
	{
		if (try reason = v.at(1))
		{
			if (try n = reason.as_u32()) return n;
		}
	}
	return 0;
}

fn long long_of(Value props, String key)
{
	if (try v = props.dict_get(key))
	{
		if (try n = v.as_i64()) return n;
	}
	return 0;
}

fn bool bool_of(Value props, String key) => bool_or(props, key, false);

fn bool bool_or(Value props, String key, bool fallback)
{
	if (try v = props.dict_get(key))
	{
		if (try b = v.as_bool()) return b;
	}
	return fallback;
}

<* A string or object-path property copied into `allocator`; "" when absent. *>
fn String text_of(Allocator allocator, Value props, String key)
{
	if (try v = props.dict_get(key))
	{
		if (try s = v.as_string()) return s.copy(allocator);
		if (try p = v.as_object_path()) return p.copy(allocator);
	}
	return "";
}

<* The object path in `props[key]`, copied into `allocator`; "" when absent. *>
fn String path_of(Allocator allocator, Value props, String key)
{
	if (try v = props.dict_get(key))
	{
		if (try p = v.as_object_path()) return p.copy(allocator);
	}
	return "";
}

<* Octets of an `ay` property, copied into `allocator`; empty when absent. *>
fn char[] bytes_of(Allocator allocator, Value props, String key)
{
	if (try v = props.dict_get(key))
	{
		if (try bytes = nm_settings::bytes_from(allocator, v)) return bytes;
	}
	return { };
}

<*
 Call a method with no arguments on `proxy` and return the first value of its
 reply, copied into `allocator`.

 @return? error::DISCONNECTED : "The bus closed before the reply arrived"
 @return? error::UNAVAILABLE : "NetworkManager rejected the call"
*>
fn Value? method_value(Proxy* proxy, String member, Allocator allocator)
{
	Message* call = proxy.new_call(mem, member)!;
	defer call.release();
	Message* reply = proxy.connection.call(call)!;
	defer reply.release();
	return reply.reader()!.read_value(allocator);
}

<* Call a method that takes one string and returns nothing. *>
fn void? method_string(Proxy* proxy, String member, String argument)
{
	Message* call = proxy.new_call(mem, member)!;
	defer call.release();
	call.body_writer("s")!.append_string(argument)!;
	Message* reply = proxy.connection.call(call)!;
	defer reply.release();
}

<* Call a method with no arguments and no reply value. *>
fn void? method_void(Proxy* proxy, String member)
{
	Message* call = proxy.new_call(mem, member)!;
	defer call.release();
	Message* reply = proxy.connection.call(call)!;
	defer reply.release();
}

<*
 Make a proxy for an object of NetworkManager. The connection must outlive it.
*>
fn Proxy? object_proxy(Connection* bus, String path, String iface) => proxy::for_object(bus, NM_SERVICE, path, iface);