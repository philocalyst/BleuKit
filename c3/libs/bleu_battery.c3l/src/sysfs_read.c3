<*
 Reading `/sys/class/power_supply` into a `State`.

 Each directory under power_supply is one source. Attributes are one-line
 files; a missing attribute is normal (drivers expose what the hardware has)
 and leaves the matching `Maybe` empty.
*>
module bleu::battery::sysfs @feat(LINUX);
import std::collections::list, std::collections::maybe, std::io::path, std::time, bleu::battery, bleu::error, bleu::rt::fs, bleu::unit;

const String SUPPLY_DIR     = "/sys/class/power_supply";
const sz ATTRIBUTE_CAPACITY = 128;

<* Reads attributes of one supply directory. *>
struct Supply
{
	String dir;
	Allocator allocator; // owns every string put into the Source
}

fn String? Supply.text(&self, String name)
{
	@pool()
	{
		String path  = string::tformat("%s/%s", self.dir, name);
		char[ATTRIBUTE_CAPACITY] buffer;
		String value = fs::read_trimmed(path, buffer[..])!;
		return value.len == 0 ? NOT_FOUND~ : value.copy(self.allocator);
	};
}

fn long? Supply.number(&self, String name)
{
	@pool()
	{
		return fs::read_integer(string::tformat("%s/%s", self.dir, name));
	};
}

fn String Supply.text_or_empty(&self, String name) => self.text(name) ?? "";

<*
 Read one supply. Returns `NOT_FOUND` for a supply without a `type`, which is
 how the kernel marks something that is not (yet) a real device.
*>
fn Source? read_supply(Allocator allocator, String root, String name)
{
	Supply supply = { .dir = string::format(allocator, "%s%s/%s", root, SUPPLY_DIR, name), .allocator = allocator };
	String type   = supply.text("type")!;
	Source source = { .id = name.copy(allocator), .kind = kind_from_type(type), .present = true };
	if (try present = supply.number("present")) source.present = present != 0;
	if (source.kind == MAINS)
	{
		// A mains source counts as "present" when it is online.
		source.present = (supply.number("online") ?? 0) != 0;
		return source;
	}
	if (try status = supply.text("status")) source.state = state_from_status(status);
	source.chemistry = chemistry_from_technology(supply.text_or_empty("technology"));
	source.vendor = supply.text_or_empty("manufacturer");
	source.model = supply.text_or_empty("model_name");
	source.serial = supply.text_or_empty("serial_number");
	long? volts = supply.number("voltage_now");

	// Energy: prefer energy_* (µWh); otherwise charge_* (µAh) x voltage.
	if (try v = supply.number("energy_now")) source.energy = maybe::value(micro_to_milli(v));
	if (try v = supply.number("energy_full")) source.energy_full = maybe::value(micro_to_milli(v));
	if (try v = supply.number("energy_full_design")) source.energy_design = maybe::value(micro_to_milli(v));
	if (try vo = volts)
	{
		if (!source.energy.has_value)
		{
			if (try v = supply.number("charge_now")) source.energy = maybe::value(energy_from_charge(v, vo));
		}
		if (!source.energy_full.has_value)
		{
			if (try v = supply.number("charge_full")) source.energy_full = maybe::value(energy_from_charge(v, vo));
		}
		if (!source.energy_design.has_value)
		{
			if (try v = supply.number(
				"charge_full_design"
			)) source.energy_design = maybe::value(energy_from_charge(v, vo));
		}
	}

	if (try pct = supply.number("capacity"))
	{
		source.charge = maybe::value(unit::from_percent((float)pct));
	}
	else if (source.energy.has_value && source.energy_full.has_value)
	{
		source.charge = maybe::value(
			unit::from_ratio((double)(long)source.energy.value, (double)(long)source.energy_full.value)
		);
	}
	if (source.energy_full.has_value && source.energy_design.has_value && (long)source.energy_design.value > 0)
	{
		source.health = maybe::value(
			unit::from_ratio((double)(long)source.energy_full.value, (double)(long)source.energy_design.value)
		);
	}

	// Flow: power_now (µW), else current_now (µA) x voltage; signed by direction of flow.
	MilliWatt? flow;
	if (try v = supply.number("power_now"))
	{
		flow = (MilliWatt)(v / 1000);
	}
	else if (try c = supply.number("current_now"))
	{
		if (try vo = volts) flow = power_from_current(c, vo);
	}
	if (try f = flow)
	{
		long magnitude = (long)f < 0 ? -(long)f : (long)f;
		source.power = maybe::value((MilliWatt)(source.state == DISCHARGING ? -magnitude : magnitude));
		if (source.energy.has_value && source.energy_full.has_value)
		{
			if (source.state == DISCHARGING)
			{
				source.time_to_empty = maybe::value(hours_at((long)source.energy.value, magnitude));
			}
			else if (source.state == CHARGING)
			{
				long missing = (long)source.energy_full.value - (long)source.energy.value;
				source.time_to_full = maybe::value(hours_at(missing, magnitude));
			}
		}
	}
	if (try v = supply.number("time_to_empty_now")) source.time_to_empty = maybe::value((Duration)(v * 1_000_000));
	if (try v = supply.number("time_to_full_now")) source.time_to_full = maybe::value((Duration)(v * 1_000_000));
	if (try v = supply.number("cycle_count")) source.cycles = maybe::value((uint)v);
	if (try v = supply.number("temp")) source.temperature = maybe::value(celsius_from_tenths(v));
	return source;
}

<*
 Read every supply under `root` into `list`. Sorted by id so the result is
 deterministic and snapshots compare equal when nothing changed.
*>
fn State? read_all(Allocator allocator, String root)
{
	@pool()
	{
		PathList names = fs::list_dir(tmem, string::tformat("%s%s", root, SUPPLY_DIR))!;
		List{Source} sources;
		sources.init(tmem);
		foreach (name : names)
		{
			Source? source = read_supply(allocator, root, (String)name);
			if (catch err = source) continue; // not a real device (yet), or vanished while reading
			sources.push(source);
		}
		sort_by_id(sources.array_view());
		State state = { .sources = alloc::clone_slice(allocator, sources.array_view()) };
		foreach (&s : state.sources)
		{
			if (s.kind == MAINS && s.present) state.on_mains = true;
		}
		return state;
	};
}

// Insertion sort: there are a handful of supplies.
fn void sort_by_id(Source[] sources) @local
{
	for (sz i = 1; i < sources.len; i++)
	{
		Source key = sources[i];
		sz j       = i - 1;
		while (j >= 0 && sources[j].id.compare_to(key.id) > 0)
		{
			sources[j + 1] = sources[j];
			j--;
		}
		sources[j + 1] = key;
	}
}