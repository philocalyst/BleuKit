<*
 BlueZ's object tree as Bleu state, and the events for what changed between
 two states. Everything here runs on the worker thread.
*>
module bleu::bluetooth::bluez @feat(LINUX);
import std::collections::list, std::collections::maybe, std::io, bleu::bluetooth, bleu::dbus::connection, bleu::dbus::message, bleu::dbus::proxy, bleu::dbus::value, bleu::equal, bleu::error, bleu::observe, bleu::unit;

// Which adapter object path belongs to which adapter address, for resolving a device's adapter.
struct AdapterLink
{
	String path;
	String address;
}

<*
 Read the whole tree and publish it, unless nothing changed. An unreadable tree leaves the state as it
 was: a failed read says nothing about the devices, so no removal is announced for them. The next change
 reads the tree again.
*>
fn void refresh(Bluez* self, BluetoothHub* hub)
{
	Snapshot{State}* snapshot = hub.begin();
	if (catch read_tree(self, snapshot.allocator(), &snapshot.value))
	{
		io::eprintfn("bleu: bluetooth: could not read BlueZ's objects (%s); keeping the last state", error::last().message());
		snapshot.release();
		return;
	}
	bluetooth::publish_changes(hub, snapshot);
}

<*
 Read GetManagedObjects into `state`, every string and slice allocated in
 `allocator`. The intermediate lists live in the temporary allocator.
*>
fn void? read_tree(Bluez* self, Allocator allocator, State* state) @private
{
	@pool()
	{
		Proxy root       = proxy::for_object(&self.bus, BLUEZ_NAME, BLUEZ_ROOT, proxy::OBJECT_MANAGER_INTERFACE)!;
		Value tree       = root.get_managed_objects(tmem)!;
		bool kill_switch = rfkill_blocked(self.root);
		List{AdapterLink} links;
		links.init(tmem);
		List{Adapter} adapters;
		adapters.init(tmem);
		foreach (object : tree.items)
		{
			if (try props = interface_props(object, ADAPTER_IFACE))
			{
				Adapter adapter = read_adapter(props, kill_switch, allocator);
				links.push({ .path = object.items[0].text, .address = adapter.address });
				adapters.push(adapter);
			}
		}
		List{Device} devices;
		devices.init(tmem);
		foreach (object : tree.items)
		{
			if (try props = interface_props(object, DEVICE_IFACE))
			{
				devices.push(read_device(object, props, links.array_view(), allocator));
			}
		}
		state.adapters = alloc::clone_slice(allocator, adapters.array_view());
		state.devices = alloc::clone_slice(allocator, devices.array_view());
		bluetooth::sort_adapters(state.adapters);
		bluetooth::sort_devices(state.devices);
	};
}

// The properties of `interface_name` on one object of the tree, or an excuse when it has none.
fn Value? interface_props(Value object, String interface_name) @inline => object.items[1].dict_get(interface_name);

fn Adapter read_adapter(Value props, bool kill_switch, Allocator allocator) @private
{
	String address  = text_prop(props, "Address", allocator);
	String name     = text_prop(props, "Name", allocator);
	String nickname = text_prop(props, "Alias", allocator);
	return {
		.address = address,
		.name = name,
		.display_name = nickname.len > 0 ? nickname : name,
		.powered = maybe::value(bool_prop(props, "Powered")), // BlueZ reports a kill switch as PowerState off-blocked; sysfs reports it for every radio.
		.blocked = kill_switch || text_prop(props, "PowerState", allocator) == "off-blocked",
		.discoverable = bool_prop(props, "Discoverable"),
		.discoverable_timeout_s = u32_prop(props, "DiscoverableTimeout"),
		.pairable = bool_prop(props, "Pairable"),
		.discovering = bool_prop(props, "Discovering"),
	};
}

fn Device read_device(Value object, Value props, AdapterLink[] links, Allocator allocator) @private
{
	String address      = text_prop(props, "Address", allocator);
	String name         = text_prop(props, "Name", allocator);
	String nickname     = text_prop(props, "Alias", allocator);
	String adapter_path = path_prop(props, "Adapter", tmem);
	String adapter      = "";
	foreach (link : links)
	{
		if (link.path == adapter_path) adapter = link.address;
	}
	uint class_of_device = u32_prop(props, "Class");
	ushort appearance    = u16_prop(props, "Appearance");
	String modalias      = text_prop(props, "Modalias", allocator);
	String[] uuids       = string_list(props, "UUIDs", allocator);
	Profile[] profiles   = profiles_of(uuids, allocator);
	Maybe{Level} battery = { };
	if (try battery_props = interface_props(object, BATTERY_IFACE))
	{
		if (try pct = battery_props.dict_get("Percentage"))
		{
			if (try percent = pct.as_byte()) battery = bluetooth::battery_level((uint)percent);
		}
	}
	Maybe{Dbm} rssi = { };
	if (try r = props.dict_get("RSSI"))
	{
		if (try dbm = r.as_i16()) rssi = maybe::value((Dbm)dbm);
	}
	return {
		.address = address,
		.adapter = bluetooth::copy_text(adapter, allocator),
		.name = name,
		.display_name = nickname.len > 0 ? nickname : (name.len > 0 ? name : address),
		.icon = bluetooth::icon_of(class_of_device, appearance),
		.class_of_device = class_of_device,
		.appearance = appearance,
		.paired = bool_prop(props, "Paired"),
		.bonded = bool_prop(props, "Bonded"),
		.connected = bool_prop(props, "Connected"),
		.trusted = bool_prop(props, "Trusted"),
		.blocked = bool_prop(props, "Blocked"),
		.services_resolved = bool_prop(props, "ServicesResolved"),
		.rssi = rssi,
		.battery = battery,
		.pnp = bluetooth::parse_modalias(modalias),
		.modalias = modalias,
		.uuids = uuids,
		.profiles = profiles,
	};
}

// The profiles among `uuids`, in the order they were reported.
fn Profile[] profiles_of(String[] uuids, Allocator allocator) @private
{
	@pool()
	{
		List{Profile} found;
		found.init(tmem);
		foreach (uuid : uuids)
		{
			if (try profile = bluetooth::profile_from_uuid(uuid)) found.push(profile);
		}
		return alloc::clone_slice(allocator, found.array_view());
	};
}

// The object path of an object-path property, copied into `allocator`; "" when absent.
fn String path_prop(Value props, String name, Allocator allocator) @private
{
	if (try v = props.dict_get(name))
	{
		if (try p = v.as_object_path()) return bluetooth::copy_text(p, allocator);
	}
	return "";
}

// The text of a string property, copied into `allocator`; "" when absent or not a string.
fn String text_prop(Value props, String name, Allocator allocator) @private
{
	if (try v = props.dict_get(name))
	{
		if (try s = v.as_string()) return bluetooth::copy_text(s, allocator);
	}
	return "";
}

fn String[] string_list(Value props, String name, Allocator allocator) @private
{
	if (try v = props.dict_get(name))
	{
		Value array  = v.unwrap();
		String[] out = alloc::new_array(allocator, String, (sz)array.count());
		for (usz i = 0; i < out.len; i++)
		{
			if (try item = array.at(i)) out[i] = bluetooth::copy_text(item.as_string() ?? "", allocator);
		}
		return out;
	}
	return { };
}

fn bool bool_prop(Value props, String name) @private
{
	if (try v = props.dict_get(name))
	{
		if (try b = v.as_bool()) return b;
	}
	return false;
}

fn uint u32_prop(Value props, String name) @private
{
	if (try v = props.dict_get(name))
	{
		if (try n = v.as_u32()) return n;
	}
	return 0;
}

fn ushort u16_prop(Value props, String name) @private
{
	if (try v = props.dict_get(name))
	{
		if (try n = v.as_u16()) return n;
	}
	return 0;
}