<*
 Reading UPower into a `State` over the system bus.

 `EnumerateDevices` lists every device object under /org/freedesktop/UPower/devices;
 each one is read with `org.freedesktop.DBus.Properties.GetAll` on its
 `org.freedesktop.UPower.Device` interface. The DisplayDevice aggregate is not
 enumerated, so it is not read: the state lists each physical device instead.

 Sources: UPower `dbus/org.freedesktop.UPower.xml` and `org.freedesktop.UPower.Device.xml`
 (interface names, method and property types); the units are in `upower_convert.c3`.
*>
module bleu::battery::upower @feat(LINUX);
import std::collections::list, std::collections::maybe, bleu::battery, bleu::dbus::connection, bleu::error, bleu::dbus::marshal, bleu::dbus::message, bleu::dbus::proxy, bleu::dbus::value;

// Names and paths of the UPower service (spec: org.freedesktop.UPower.xml).
const String UPOWER_NAME      = "org.freedesktop.UPower";
const String UPOWER_PATH      = "/org/freedesktop/UPower";
const String UPOWER_INTERFACE = "org.freedesktop.UPower";
const String DEVICE_INTERFACE = "org.freedesktop.UPower.Device";

<* A numeric property of type `u` (the spec's Type, State, Technology). NOT_FOUND when absent. *>
fn uint? prop_u32(Value props, String name)
{
	Value v = props.dict_get(name)!;
	return v.as_u32();
}

<* A property of type `i` (ChargeCycles). NOT_FOUND when absent. *>
fn int? prop_i32(Value props, String name)
{
	Value v = props.dict_get(name)!;
	return v.as_i32();
}

<* A property of type `x` (TimeToEmpty, TimeToFull). NOT_FOUND when absent. *>
fn long? prop_i64(Value props, String name)
{
	Value v = props.dict_get(name)!;
	return v.as_i64();
}

<* A property of type `d` (Energy, Percentage, Temperature ...). NOT_FOUND when absent. *>
fn double? prop_f64(Value props, String name)
{
	Value v = props.dict_get(name)!;
	return v.as_f64();
}

<* A property of type `b`. NOT_FOUND when absent. *>
fn bool? prop_bool(Value props, String name)
{
	Value v = props.dict_get(name)!;
	return v.as_bool();
}

<* A string property copied into `allocator`; "" when absent. *>
fn String prop_text(Value props, String name, Allocator allocator)
{
	if (try v = props.dict_get(name))
	{
		if (try text = v.as_string()) return text.copy(allocator);
	}
	return "";
}

<* The object path at `index` of an `ao` array, or NOT_FOUND when that is not a path. *>
fn String? object_path_at(Value paths, usz index)
{
	Value item = paths.at(index)!;
	return item.as_object_path();
}

<*
 Read one device object into a `Source`. The id is the device's NativePath, or its
 object path when UPower gives none.

 @return? error::UNAVAILABLE : "when the device cannot be read (it vanished)"
*>
fn Source? read_device(Allocator allocator, Connection* connection, String path)
{
	proxy::Proxy device = proxy::for_object(connection, UPOWER_NAME, path, DEVICE_INTERFACE)!;
	Value props         = device.get_all_properties(tmem)!;
	uint type           = prop_u32(props, "Type") ?? TYPE_UNKNOWN;
	bool power_supply   = prop_bool(props, "PowerSupply") ?? true;
	String native       = prop_text(props, "NativePath", allocator);
	Source source = {
		.id = native.len > 0 ? native : path.copy(allocator),
		.kind = device_kind(type, power_supply),
		.present = true,
	};
	if (source.kind == MAINS)
	{
		source.present = prop_bool(props, "Online") ?? false;
		return source;
	}
	source.present = prop_bool(props, "IsPresent") ?? true;
	source.chemistry = technology(prop_u32(props, "Technology") ?? 0);
	source.vendor = prop_text(props, "Vendor", allocator);
	source.model = prop_text(props, "Model", allocator);
	source.serial = prop_text(props, "Serial", allocator);
	if (!source.present) return source;
	source.state = device_state(prop_u32(props, "State") ?? STATE_UNKNOWN);
	if (try pct = prop_f64(props, "Percentage")) source.charge = charge_from_percentage(pct);
	if (try wh = prop_f64(props, "Energy")) source.energy = maybe::value(energy_from_wh(wh));
	if (try wh = prop_f64(props, "EnergyFull")) source.energy_full = maybe::value(energy_from_wh(wh));
	if (try wh = prop_f64(props, "EnergyFullDesign")) source.energy_design = maybe::value(energy_from_wh(wh));
	if (source.energy_full.has_value && source.energy_design.has_value)
	{
		source.health = battery::health_from(source.energy_full.value, source.energy_design.value);
	}
	if (try rate = prop_f64(props, "EnergyRate")) source.power = maybe::value(power_from_rate(rate));
	if (try seconds = prop_i64(props, "TimeToEmpty")) source.time_to_empty = duration_from_seconds(seconds);
	if (try seconds = prop_i64(props, "TimeToFull")) source.time_to_full = duration_from_seconds(seconds);
	if (try cycles = prop_i32(props, "ChargeCycles")) source.cycles = cycles_from((long)cycles);
	if (try celsius = prop_f64(props, "Temperature")) source.temperature = temperature_from(celsius);
	return source;
}

<*
 Read every device UPower enumerates into a `State` allocated from `allocator`.

 @return? error::UNAVAILABLE : "when UPower does not answer EnumerateDevices"
*>
fn State? read_all(Allocator allocator, Connection* connection)
{
	@pool()
	{
		proxy::Proxy root = proxy::for_object(connection, UPOWER_NAME, UPOWER_PATH, UPOWER_INTERFACE)!;
		Message* call     = root.new_call(tmem, "EnumerateDevices")!;
		defer call.release();
		Message* reply = connection.call(call)!;
		defer reply.release();
		marshal::Reader body = reply.reader()!;
		Value paths          = body.read_value(tmem)!;
		List{Source} sources;
		sources.init(tmem);
		usz skipped = 0;
		for (usz i = 0; i < paths.count(); i++)
		{
			// A device that vanishes between enumeration and reading is left out, and the reading says so.
			if (try path = object_path_at(paths, i))
			{
				if (try source = read_device(allocator, connection, path))
				{
					sources.push(source);
				}
				else
				{
					skipped++;
				}
			}
			else
			{
				skipped++;
			}
		}
		State state = { };
		state.reading = battery::reading_after(skipped);
		if (sources.array_view().len > 0)
		{
			battery::sort_by_id(sources.array_view());
			state.sources = alloc::clone_slice(allocator, sources.array_view());
		}
		foreach (&source : state.sources)
		{
			if (source.kind == MAINS && source.present) state.on_mains = true;
		}
		return state;
	};
}