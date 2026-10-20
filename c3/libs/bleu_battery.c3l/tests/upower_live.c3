// Live tests against the mock UPower of mock_upower.py. run.sh starts the private
// system bus and the mock, and sets BLEU_UPOWER_CONTROL to the control file the tests write.
module bleu::battery::upower_live_test @feat(LINUX);
import std::os::env, std::time, bleu::battery, bleu::error, bleu::observe, bleu::rt::fs;

fn String control_path() @local
{
	return env::tget_var("BLEU_UPOWER_CONTROL")!!;
}

fn void set_control(String text) @local
{
	fs::write_text(control_path(), text)!!;
}

// Take the next state after `current` (which this call releases), up to 2 s later.
fn Snapshot{State}* advance(Battery* battery, Snapshot{State}* current) @local
{
	Snapshot{State}* next = battery.wait_after(current.generation, time::ms(2000))!!;
	current.release();
	return next;
}

// Advance until the newest state has the line and battery in the wanted condition, or give up
// after `steps`. The mock applies a control change within one 50 ms tick, so a few steps suffice.
fn Snapshot{State}* settled(Battery* battery, Snapshot{State}* current, bool mains, ChargeState state, usz steps) @local
{
	Snapshot{State}* latest = current;
	for (usz i = 0; i < steps; i++)
	{
		Source* bat = &latest.value.sources[latest.value.sources.len - 1];
		if (latest.value.on_mains == mains && bat.state == state) return latest;
		latest = advance(battery, latest);
	}
	return latest;
}

// Advance until there are `count` sources, or give up after `steps`.
fn Snapshot{State}* until_sources(Battery* battery, Snapshot{State}* current, usz count, usz steps) @local
{
	Snapshot{State}* latest = current;
	for (usz i = 0; i < steps && latest.value.sources.len != count; i++)
	{
		latest = advance(battery, latest);
	}
	return latest;
}

fn void reads_the_line_and_the_battery() @test
{
	set_control("online=0 state=2 percentage=50 rate=15.0 energy=25.0 mouse=0");
	Battery* battery = battery::open(mem, { .backend = UPOWER, .poll = time::ms(50) })!!;
	defer battery.close();
	assert(battery.backend_name() == "upower", "UPower is preferred over sysfs");
	Snapshot{State}* snapshot = settled(battery, battery.wait_after(0, time::ms(3000))!!, false, DISCHARGING, 20);
	defer snapshot.release();
	State* state = &snapshot.value;
	assert(!state.on_mains, "line power is offline");
	assert(state.sources.len == 2, "AC and BAT0");
	Source* ac = &state.sources[0];
	assert(ac.id == "AC" && ac.kind == MAINS && !ac.present);
	Source* bat = &state.sources[1];
	assert(bat.id == "BAT0" && bat.kind == BATTERY && bat.state == DISCHARGING);
	assert((float)bat.charge.value == 0.5f, "Percentage 50");
	assert((long)bat.energy.value == 25_000 && (long)bat.energy_full.value == 40_000);
	assert((long)bat.energy_design.value == 50_000, "EnergyFullDesign in mWh");
	float health = (float)bat.health.value;
	assert(health > 0.79f && health < 0.81f, "40 of 50 Wh");
	// EnergyRate 15 W is positive when discharging; Bleu's flow is negative then.
	assert((long)bat.power.value == -15_000);
	assert(bat.time_to_empty.value == (Duration)5_400_000_000, "TimeToEmpty in seconds");
	assert(!bat.time_to_full.has_value, "TimeToFull is 0, so unknown");
	assert(bat.cycles.value == 212 && bat.chemistry == LITHIUM_ION);
	assert(bat.vendor == "ACME" && bat.model == "Cell9" && bat.serial == "SN-42");
	assert((float)bat.temperature.value == 31.5f);
}

fn void follows_property_changes_and_device_signals() @test
{
	set_control("online=0 state=2 percentage=50 rate=15.0 energy=25.0 mouse=0");
	Battery* battery = battery::open(mem, { .backend = UPOWER, .poll = time::ms(50) })!!;
	defer battery.close();
	// Plug in and start charging: PropertiesChanged on AC and on BAT0.
	set_control("online=1 state=1 percentage=60 rate=-20.0 energy=30.0 mouse=0");
	Snapshot{State}* charging = settled(battery, battery.wait_after(0, time::ms(3000))!!, true, CHARGING, 20);
	defer charging.release();
	assert(charging.value.on_mains, "AC went online");
	Source* bat = &charging.value.sources[1];
	assert(bat.state == CHARGING, "BAT0 charges");
	assert((long)bat.power.value == 20_000, "a negative EnergyRate is a charge: positive flow");
	// A mouse appears (DeviceAdded), then goes (DeviceRemoved).
	set_control("online=1 state=1 percentage=60 rate=-20.0 energy=30.0 mouse=1");
	Snapshot{State}* with_mouse = until_sources(
		battery,
		battery.wait_after(charging.generation, time::ms(3000))!!,
		3,
		20
	);
	defer with_mouse.release();
	assert(with_mouse.value.sources.len == 3, "DeviceAdded refreshes the sources");
	assert(with_mouse.value.sources[2].kind == PERIPHERAL);
	set_control("online=1 state=1 percentage=60 rate=-20.0 energy=30.0 mouse=0");
	Snapshot{State}* without = until_sources(
		battery,
		battery.wait_after(with_mouse.generation, time::ms(3000))!!,
		2,
		20
	);
	defer without.release();
	assert(without.value.sources.len == 2, "DeviceRemoved refreshes the sources");
}