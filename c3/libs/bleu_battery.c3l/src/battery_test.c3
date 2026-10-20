module bleu::battery::battery_test @feat(LINUX);
import std::io, std::io::path, std::time, bleu::availability, bleu::battery, bleu::error, bleu::observe, bleu::rt::fs;

// mkdtemp(3) (glibc, musl, Darwin): a new empty directory with an unpredictable name.
extern fn char* mkdtemp(char* template) @cname("mkdtemp");

<*
 A fake /sys/class/power_supply tree under a fresh directory: one laptop battery with
 `status` and `current_now` (a negative current is a discharge), and one adapter that is
 `online`. Remove it with `path::rmtree` on the returned root.
*>
fn String fake_tree(String status, String online, String current) @local
{
	char[32] template = "/tmp/bleu-battery-XXXXXX";
	ZString dir       = (ZString)mkdtemp(&template[0]);
	String root       = string::tformat("%s", dir);
	String bat        = string::tformat("%s/sys/class/power_supply/BAT0", root);
	String ac         = string::tformat("%s/sys/class/power_supply/AC", root);
	path::mkdir((Path)bat, true)!!;
	path::mkdir((Path)ac, true)!!;
	String[2][*] battery_files = {
		{ "type", "Battery" },
		{ "status", status },
		{ "technology", "Li-ion" },
		{ "manufacturer", "ACME" },
		{ "model_name", "Cell9" },
		{ "present", "1" },
		{ "voltage_now", "11100000" },
		{ "charge_now", "1000000" },
		{ "charge_full", "2000000" },
		{ "charge_full_design", "2500000" },
		{ "current_now", current },
		{ "cycle_count", "212" },
		{ "temp", "312" },
	};
	foreach (entry : battery_files) fs::write_text(string::tformat("%s/%s", bat, entry[0]), entry[1])!!;
	fs::write_text(string::tformat("%s/type", ac), "Mains")!!;
	fs::write_text(string::tformat("%s/online", ac), online)!!;
	return root;
}

fn void reads_a_charging_laptop() @test
{
	String root = fake_tree("Charging", "1", "1500000");
	defer path::rmtree((Path)root)!!;
	Battery* battery = battery::open(mem, { .backend = SYSFS, .root = root, .poll = time::ms(50) })!!;
	defer battery.close();
	assert(battery.backend_name() == "sysfs");
	Snapshot{State}* snapshot = battery.wait_after(0, time::ms(2000))!!;
	defer snapshot.release();
	State* state = &snapshot.value;
	assert(state.on_mains, "adapter is online");
	assert(state.reading.ok() && state.reading.reason == availability::Reason.AVAILABLE, "a full reading");
	assert(state.sources.len == 2, "AC and BAT0");
	Source* bat = &state.sources[1];
	assert(bat.id == "BAT0" && bat.kind == BATTERY && bat.state == CHARGING);
	assert((long)bat.energy.value == 11_100, "1 Ah at 11.1 V is 11.1 Wh");
	assert((long)bat.energy_full.value == 22_200);
	float charge = (float)bat.charge.value;
	assert(charge > 0.49f && charge < 0.51f, "half full");
	float health = (float)bat.health.value;
	assert(health > 0.79f && health < 0.81f, "2.0 of 2.5 Ah");
	assert((long)bat.power.value == 16_650, "1.5 A at 11.1 V, charging");
	// 11.1 Wh still to store at 16.65 W: 2400 s.
	assert(bat.time_to_full.value == (Duration)2_400_000_000, "time to full from the missing energy and the flow");
	assert(bat.cycles.value == 212 && bat.chemistry == LITHIUM_ION && bat.vendor == "ACME");
	assert((float)bat.temperature.value == 31.2f);
}

fn void reads_a_discharging_laptop() @test
{
	String root = fake_tree("Discharging", "0", "-1500000");
	defer path::rmtree((Path)root)!!;
	Battery* battery = battery::open(mem, { .backend = SYSFS, .root = root, .poll = time::ms(50) })!!;
	defer battery.close();
	Snapshot{State}* snapshot = battery.wait_after(0, time::ms(2000))!!;
	defer snapshot.release();
	assert(!snapshot.value.on_mains, "adapter is offline");
	Source* bat = &snapshot.value.sources[1];
	assert(bat.state == DISCHARGING, "negative current_now is a discharge");
	assert((long)bat.power.value == -16_650, "the flow is out of the battery");
	// 11.1 Wh at 16.65 W: 2400 s.
	assert(bat.time_to_empty.value == (Duration)2_400_000_000, "time to empty from the stored energy and the flow");
	assert(!bat.time_to_full.has_value, "nothing to fill while discharging");
}

fn void publishes_only_real_changes() @test
{
	String root = fake_tree("Discharging", "0", "-1500000");
	defer path::rmtree((Path)root)!!;
	Battery* battery = battery::open(mem, { .backend = SYSFS, .root = root, .poll = time::ms(20) })!!;
	defer battery.close();
	Snapshot{State}* first = battery.wait_after(0, time::ms(2000))!!;
	ulong generation       = first.generation;
	assert(!first.value.on_mains);
	first.release();
	// Nothing changes on disk: no new generation within several polls.
	assert(@catch(battery.wait_after(generation, time::ms(150))) == TIMEOUT);
	// Plug in: the next poll publishes exactly one new generation.
	fs::write_text(string::tformat("%s/sys/class/power_supply/AC/online", root), "1")!!;
	Snapshot{State}* second = battery.wait_after(generation, time::ms(2000))!!;
	assert(second.value.on_mains && second.generation == generation + 1);
	second.release();
}

// Plugging in is a transient: a subscriber gets MAINS_CHANGED, not only a new generation.
fn void plugging_in_is_published_as_an_event() @test
{
	String root = fake_tree("Discharging", "0", "-1500000");
	defer path::rmtree((Path)root)!!;
	Battery* battery = battery::open(mem, { .backend = SYSFS, .root = root, .poll = time::ms(20) })!!;
	defer battery.close();
	Snapshot{State}* first = battery.wait_after(0, time::ms(2000))!!;
	first.release();
	if (try reader = battery.subscribe())
	{
		defer reader.release();
		fs::write_text(string::tformat("%s/sys/class/power_supply/AC/online", root), "1")!!;
		if (try packet = reader.next(time::ms(2000)))
		{
			defer packet.release();
			assert(packet.value.kind == MAINS_CHANGED, "the mains line changed");
		}
		else
		{
			assert(false, "a MAINS_CHANGED event within two seconds");
		}
	}
	else
	{
		assert(false, "subscribe to events");
	}
}

// A read that fails keeps the last good sources and says so; it never publishes an empty state.
fn void a_failed_read_keeps_the_last_good_reading() @test
{
	String root = fake_tree("Discharging", "0", "-1500000");
	defer path::rmtree((Path)root)!!;
	Battery* battery = battery::open(mem, { .backend = SYSFS, .root = root, .poll = time::ms(20) })!!;
	defer battery.close();
	Snapshot{State}* good = battery.wait_after(0, time::ms(2000))!!;
	defer good.release();
	assert(good.value.sources.len == 2 && good.value.reading.ok());
	// The supply directory vanishes: the next read fails.
	path::rmtree((Path)string::tformat("%s/sys/class/power_supply", root))!!;
	Snapshot{State}* stale = battery.wait_after(good.generation, time::ms(2000))!!;
	defer stale.release();
	assert(stale.value.sources.len == 2, "the last good sources are kept, not replaced by an empty state");
	assert(stale.value.reading.reason == availability::Reason.BACKEND_STOPPED, "the reading is marked stale");
	assert(!stale.value.reading.ok(), "a stale reading is not OK");
}

fn void without_the_subsystem_no_backend_opens() @test
{
	assert(@catch(battery::open(mem, { .root = "/nonexistent-root" })) == error::UNAVAILABLE);
}