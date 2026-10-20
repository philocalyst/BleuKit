<*
 Mounts (statvfs), network rates and temperature sensors from /proc, /sys and
 /proc/mounts. Missing optional sources give empty lists, never an error.
*>
module bleu::sysinfo::procfs @feat(LINUX);
import std::io::path, std::time, std::collections::list, bleu::error, bleu::rt::fs, bleu::rt::unix, bleu::sysinfo, bleu::sysinfo::delta, libc;

<*
 Local disks with their usage. A device that appears under several mount
 points is listed once, under its first mount point.

 @return? error::PROTOCOL, NOT_FOUND : "/proc/mounts could not be read"
*>
fn Mount[]? read_mounts(String root, Allocator allocator)
{
	RawMount[] raw = procfs::parse_mounts(read_text(root, "/proc/mounts")!, tmem)!;
	List{Mount} mounts;
	mounts.init(tmem);
	foreach (&entry : raw)
	{
		if (!procfs::is_local_disk(entry.device) || has_device(&mounts, entry.device)) continue;
		// A mount point that vanished between the two reads is skipped, not reported as empty.
		if (try mount = statvfs_mount(root, entry, allocator)) mounts.push(mount);
	}
	return alloc::clone_slice(allocator, mounts.array_view());
}

fn bool has_device(List{Mount}* mounts, String device)
{
	foreach (&mount : mounts)
	{
		if (mount.device == device) return true;
	}
	return false;
}

fn Mount? statvfs_mount(String root, RawMount* entry, Allocator allocator)
{
	Statvfs vfs;
	ZString path = string::tformat("%s%s", root, entry.mount_point).zstr_tcopy();
	if (sys_statvfs(path, &vfs) != 0) return unix::errno_fault("statvfs", libc::errno())~;
	ulong unit  = vfs.f_frsize != 0 ? vfs.f_frsize : vfs.f_bsize;
	Bytes total = vfs.f_blocks * unit;
	Bytes free  = vfs.f_bfree * unit;
	return {
		.device = entry.device.copy(allocator),
		.mount_point = entry.mount_point.copy(allocator),
		.fs_type = entry.fs_type.copy(allocator),
		.total = total,
		.used = total - free,
		.available = vfs.f_bavail * unit,
	};
}

<* Cumulative counters of every non-loopback interface, in tmem. *>
fn delta::NetCounters[]? read_net_counters(String root)
{
	return procfs::parse_net_dev(read_text(root, "/proc/net/dev")!, tmem);
}

// Keep the counters of this sample for the next rate. Old names are freed; new ones belong to the backend.
<*
 Every temperature sensor: hwmon chips (`temp<N>_input`, labelled by
 `temp<N>_label` when present) and thermal zones. Sorted by name so that equal
 readings compare equal across samples.
*>
fn Temperature[] read_temperatures(String root, Allocator allocator)
{
	List{Temperature} sensors;
	sensors.init(tmem);
	add_hwmon_sensors(root, &sensors);
	add_thermal_sensors(root, &sensors);
	Temperature[] result = alloc::new_array(allocator, Temperature, sensors.array_view().len);
	foreach (i, &sensor : sensors.array_view())
	{
		result[i] = { .name = sensor.name.copy(allocator), .value = sensor.value };
	}
	sort_by_name(result);
	return result;
}

fn void add_hwmon_sensors(String root, List{Temperature}* sensors)
{
	String base     = string::tformat("%s/sys/class/hwmon", root);
	PathList? chips = fs::list_dir(tmem, base);
	if (catch err = chips) return; // no hwmon class: no sensors, which is not a failure
	foreach (chip : chips)
	{
		String dir       = string::tformat("%s/%s", base, (String)chip);
		String chip_name = read_attribute(string::tformat("%s/name", dir)) ?? (String)chip;
		PathList? files  = fs::list_dir(tmem, dir);
		if (catch err = files) continue;
		foreach (file : files)
		{
			if (try index = procfs::numbered_name((String)file, "temp", "_input"))
			{
				add_hwmon_sensor(sensors, dir, chip_name, index);
			}
		}
	}
}

fn void add_hwmon_sensor(List{Temperature}* sensors, String dir, String chip, int index)
{
	String label = read_attribute(string::tformat("%s/temp%d_label", dir, index)) ?? string::tformat("temp%d", index);
	if (try text = read_attribute(string::tformat("%s/temp%d_input", dir, index)))
	{
		if (try celsius = procfs::celsius_from_millidegrees(text))
		{
			sensors.push({ .name = string::tformat("%s %s", chip, label), .value = celsius });
		}
	}
}

fn void add_thermal_sensors(String root, List{Temperature}* sensors)
{
	String base     = string::tformat("%s/sys/class/thermal", root);
	PathList? zones = fs::list_dir(tmem, base);
	if (catch err = zones) return;
	foreach (zone : zones)
	{
		if (catch procfs::numbered_name((String)zone, "thermal_zone", "")) continue;
		String dir  = string::tformat("%s/%s", base, (String)zone);
		String kind = read_attribute(string::tformat("%s/type", dir)) ?? (String)zone;
		if (try text = read_attribute(string::tformat("%s/temp", dir)))
		{
			if (try celsius = procfs::celsius_from_millidegrees(text))
			{
				sensors.push({ .name = kind, .value = celsius });
			}
		}
	}
}

// Insertion sort: there are a few dozen sensors at most.
fn void sort_by_name(Temperature[] sensors)
{
	for (sz i = 1; i < sensors.len; i++)
	{
		Temperature key = sensors[i];
		sz j            = i - 1;
		while (j >= 0 && sensors[j].name.compare_to(key.name) > 0)
		{
			sensors[j + 1] = sensors[j];
			j--;
		}
		sensors[j + 1] = key;
	}
}