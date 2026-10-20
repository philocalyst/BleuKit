<*
 BlueZ's object tree as Bleu state, and the events for what changed between
 two states. Everything here runs on the worker thread.
*>
module bleu::bluetooth::bluez @feat(LINUX);
import std::collections::list, std::collections::maybe, bleu::bluetooth, bleu::dbus::connection,
	bleu::dbus::message, bleu::dbus::proxy, bleu::dbus::value, bleu::equal, bleu::error, bleu::observe, bleu::unit;

// Which adapter object path belongs to which adapter address, for resolving a device's adapter.
struct AdapterLink
{
	String path;
	String address;
}

<* Read the whole tree and publish it, unless nothing changed. An unreadable tree is an empty one. *>
fn void refresh(Bluez* self, BluetoothHub* hub)
{
	Snapshot{State}* snapshot = hub.begin();
	if (catch read_tree(self, snapshot.allocator(), &snapshot.value))
	{
		snapshot.value = { };
	}
	publish_changes(hub, snapshot);
}

// Publishes `snapshot` if it differs from the latest, emitting the events of the difference. Consumes `snapshot`.
fn void publish_changes(BluetoothHub* hub, Snapshot{State}* snapshot)
{
	Snapshot{State}* previous = null;
	if (try latest = hub.latest()) previous = latest;
	if (previous && equal::deep(previous.value, snapshot.value))
	{
		previous.release();
		snapshot.release();
		return;
	}
	Snapshot{State}* kept = snapshot.retain();
	hub.publish(snapshot);
	State empty;
	State before = previous ? previous.value : empty;
	emit_differences(hub, &before, &kept.value);
	if (previous) previous.release();
	kept.release();
}

// Events for every adapter and device that appeared, changed or vanished between two states.
fn void emit_differences(BluetoothHub* hub, State* before, State* after) @private
{
	foreach (&adapter : after.adapters)
	{
		sz old = find_adapter(before.adapters, adapter.address);
		if (old < 0) emit(hub, ADAPTER_ADDED, adapter.address, "");
		else if (!equal::deep(before.adapters[old], adapter)) emit(hub, ADAPTER_CHANGED, adapter.address, "");
	}
	foreach (&adapter : before.adapters)
	{
		if (find_adapter(after.adapters, adapter.address) < 0) emit(hub, ADAPTER_REMOVED, adapter.address, "");
	}
	foreach (&device : after.devices)
	{
		sz old = find_device(before.devices, device.address);
		if (old < 0) emit(hub, DEVICE_ADDED, device.address, "");
		else if (!equal::deep(before.devices[old], device)) emit(hub, DEVICE_CHANGED, device.address, "");
	}
	foreach (&device : before.devices)
	{
		if (find_device(after.devices, device.address) < 0) emit(hub, DEVICE_REMOVED, device.address, "");
	}
}

fn sz find_adapter(Adapter[] adapters, String address) @private
{
	foreach (i, &adapter : adapters)
	{
		if (adapter.address == address) return i;
	}
	return -1;
}

fn sz find_device(Device[] devices, String address) @private
{
	foreach (i, &device : devices)
	{
		if (device.address == address) return i;
	}
	return -1;
}

<* Send one event. The strings are copied into the event's own arena. *>
fn void emit(BluetoothHub* hub, EventKind kind, String address, String text)
{
	Snapshot{Event}* packet = hub.emit_begin();
	Allocator arena = packet.allocator();
	packet.value = { .kind = kind, .address = copy_text(address, arena), .text = copy_text(text, arena) };
	hub.emit(packet);
}

<*
 Read GetManagedObjects into `state`, every string and slice allocated in
 `allocator`. The intermediate lists live in the temporary allocator.
*>
fn void? read_tree(Bluez* self, Allocator allocator, State* state) @private
{
	@pool()
	{
		Proxy root = proxy::for_object(&self.bus, BLUEZ_NAME, BLUEZ_ROOT, proxy::OBJECT_MANAGER_INTERFACE)!;
		Value tree = root.get_managed_objects(tmem)!;
		bool kill_switch = rfkill_blocked(self.root);
		List{AdapterLink} links;
		links.init(tmem);
		List{Adapter} adapters;
		adapters.init(tmem);
		foreach (object : tree.items)
		{
			if (try props = interface_props(object, ADAPTER_IFACE))
			{
				Adapter adapter = read_adapter(props, object.items[0].text, kill_switch, allocator);
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
		sort_adapters(state.adapters);
		sort_devices(state.devices);
	};
}

// The properties of `interface_name` on one object of the tree, or an excuse when it has none.
fn Value? interface_props(Value object, String interface_name) @inline => object.items[1].dict_get(interface_name);

fn Adapter read_adapter(Value props, String path, bool kill_switch, Allocator allocator) @private
{
	String address = text_prop(props, "Address", allocator);
	String name = text_prop(props, "Name", allocator);
	String alias = text_prop(props, "Alias", allocator);
	return {
		.address = address,
		.name = name,
		.display_name = alias.len > 0 ? alias : name,
		.powered = bool_prop(props, "Powered"),
		// BlueZ reports a kill switch as PowerState off-blocked; sysfs reports it for every radio.
		.blocked = kill_switch || text_prop(props, "PowerState", allocator) == "off-blocked",
		.discoverable = bool_prop(props, "Discoverable"),
		.discoverable_timeout_s = u32_prop(props, "DiscoverableTimeout"),
		.pairable = bool_prop(props, "Pairable"),
		.discovering = bool_prop(props, "Discovering"),
	};
}

fn Device read_device(Value object, Value props, AdapterLink[] links, Allocator allocator) @private
{
	String address = text_prop(props, "Address", allocator);
	String name = text_prop(props, "Name", allocator);
	String alias = text_prop(props, "Alias", allocator);
	String adapter_path = text_prop(props, "Adapter", tmem);
	String adapter = "";
	foreach (link : links)
	{
		if (link.path == adapter_path) adapter = link.address;
	}
	uint class_of_device = u32_prop(props, "Class");
	ushort appearance = u16_prop(props, "Appearance");
	String modalias = text_prop(props, "Modalias", allocator);
	String[] uuids = string_list(props, "UUIDs", allocator);
	Profile[] profiles = profiles_of(uuids, allocator);
	Maybe{Level} battery = { };
	if (try battery_props = interface_props(object, BATTERY_IFACE))
	{
		if (try pct = battery_props.dict_get("Percentage"))
		{
			if (try value = pct.as_byte()) battery = battery_level((uint)value);
		}
	}
	Maybe{Dbm} rssi = { };
	if (try r = props.dict_get("RSSI"))
	{
		if (try value = r.as_i16()) rssi = maybe::value((Dbm)value);
	}
	return {
		.address = address,
		.adapter = copy_text(adapter, allocator),
		.name = name,
		.display_name = alias.len > 0 ? alias : (name.len > 0 ? name : address),
		.icon = icon_of(class_of_device, appearance),
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
		.pnp = modalias.len > 0 ? parse_modalias(modalias) : { },
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
			if (try profile = profile_from_uuid(uuid)) found.push(profile);
		}
		return alloc::clone_slice(allocator, found.array_view());
	};
}

// The text of a string property, copied into `allocator`; "" when absent or not a string.
fn String text_prop(Value props, String name, Allocator allocator) @private
{
	if (try v = props.dict_get(name))
	{
		if (try s = v.as_string()) return copy_text(s, allocator);
	}
	return "";
}

fn String[] string_list(Value props, String name, Allocator allocator) @private
{
	if (try v = props.dict_get(name))
	{
		Value list = v.unwrap();
		String[] out = alloc::new_array(allocator, String, (sz)list.count());
		for (usz i = 0; i < out.len; i++)
		{
			out[i] = list.at(i)!.as_string() ?? "";
			out[i] = copy_text(out[i], allocator);
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

// Adapters by address, so that the state order does not depend on BlueZ's object order.
fn void sort_adapters(Adapter[] adapters) @private
{
	for (sz i = 1; i < adapters.len; i++)
	{
		Adapter key = adapters[i];
		sz j = i - 1;
		while (j >= 0 && adapters[j].address.compare_to(key.address) > 0)
		{
			adapters[j + 1] = adapters[j];
			j--;
		}
		adapters[j + 1] = key;
	}
}

fn void sort_devices(Device[] devices) @private
{
	for (sz i = 1; i < devices.len; i++)
	{
		Device key = devices[i];
		sz j = i - 1;
		while (j >= 0 && devices[j].address.compare_to(key.address) > 0)
		{
			devices[j + 1] = devices[j];
			j--;
		}
		devices[j + 1] = key;
	}
}
