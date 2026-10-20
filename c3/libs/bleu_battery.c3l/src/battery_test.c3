module bleu::battery::battery_test @feat(LINUX);
import std::io, std::io::path, std::time, std::time::clock, bleu::battery, bleu::error, bleu::observe, bleu::rt::fs;

// Build a fake /sys/class/power_supply tree: one laptop battery (charge_*-style) and one adapter.
fn String fake_tree(String stem, String status, String online) @local
{
	String root = string::tformat("/tmp/bleu-battery-%s-%d", stem, clock::now());
	String bat  = string::tformat("%s/sys/class/power_supply/BAT0", root);
	String ac   = string::tformat("%s/sys/class/power_supply/AC", root);
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
		{ "current_now", "1500000" },
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
	String root      = fake_tree("charging", "Charging", "1");
	Battery* battery = battery::open(mem, { .backend = SYSFS, .root = root, .poll = time::ms(50) })!!;
	defer battery.close();
	assert(battery.backend_name() == "sysfs");
	Snapshot{State}* snapshot = battery.wait_after(0, time::ms(2000))!!;
	defer snapshot.release();
	State* state = &snapshot.value;
	assert(state.on_mains, "adapter is online");
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
	assert(bat.time_to_full.has_value, "estimate from flow");
	assert(bat.cycles.value == 212 && bat.chemistry == LITHIUM_ION && bat.vendor == "ACME");
	assert((float)bat.temperature.value == 31.2f);
}

fn void publishes_only_real_changes() @test
{
	String root      = fake_tree("changes", "Discharging", "0");
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

fn void without_the_subsystem_no_backend_opens() @test
{
	assert(@catch(battery::open(mem, { .root = "/nonexistent-root" })) == error::UNAVAILABLE);
}