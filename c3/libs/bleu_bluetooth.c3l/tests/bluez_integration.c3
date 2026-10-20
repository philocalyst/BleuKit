// Drives the BlueZ backend through the public API against tests/mock_bluez.py.
// Run by tests/run.sh with two arguments: the bus address and an rfkill root.
// Prints one PASS or FAIL line per check and exits non-zero when any check fails.
module bluez_integration @feat(LINUX);
import std::io, std::time, bleu::bluetooth, bleu::error, bleu::observe, bleu::operation, bleu::rt::fs, bleu::stream;

alias State = bluetooth::State;
alias Device = bluetooth::Device;
alias Task = bluetooth::Task;
alias Bluetooth = bluetooth::Bluetooth;
alias Event = bluetooth::Event;

const String HEADSET = "AA:BB:CC:DD:EE:01";
const String MOUSE = "AA:BB:CC:DD:EE:02";
const String KEYBOARD = "AA:BB:CC:DD:EE:03";
const String PHONE = "AA:BB:CC:DD:EE:04";
const ulong WAIT_MS = 200;
const int WAIT_ROUNDS = 50;
const ulong TASK_MS = 10000;
const int EVENT_ROUNDS = 2000;

alias Check = fn bool(State* state);

int failures = 0;

fn void expect(bool condition, String what)
{
	io::printfn("%s %s", condition ? "PASS" : "FAIL", what);
	if (!condition) failures++;
}

fn Device* device_at(State* state, String address)
{
	for (usz i = 0; i < state.devices.len; i++)
	{
		if (state.devices[i].address == address) return &state.devices[i];
	}
	return null;
}

fn bool has_device(State* state, String address) => device_at(state, address) != null;

fn bool dev_powered(State* state) => state.adapters.len > 0 && state.adapters[0].powered;

fn bool dev_blocked(State* state) => state.adapters.len > 0 && state.adapters[0].blocked;

fn bool dev_unblocked(State* state) => state.adapters.len > 0 && !state.adapters[0].blocked;

fn bool headset_paired(State* state)
{
	Device* d = device_at(state, HEADSET);
	return d != null && d.paired && d.bonded;
}

fn bool headset_connected(State* state)
{
	Device* d = device_at(state, HEADSET);
	return d != null && d.connected;
}

fn bool headset_disconnected(State* state)
{
	Device* d = device_at(state, HEADSET);
	return d != null && !d.connected;
}

fn bool keyboard_seen(State* state) => has_device(state, KEYBOARD);

fn bool mouse_seen(State* state) => has_device(state, MOUSE);

fn bool mouse_gone(State* state) => !has_device(state, MOUSE);

fn bool headset_managed(State* state)
{
	Device* d = device_at(state, HEADSET);
	return d != null && d.trusted && d.blocked && d.display_name == "Renamed Headset";
}

// Waits until a published state satisfies `check`, or gives up after about WAIT_ROUNDS * WAIT_MS.
fn bool settle(Bluetooth* bt, Check check)
{
	ulong seen = 0;
	for (int i = 0; i < WAIT_ROUNDS; i++)
	{
		if (try snapshot = bt.wait_after(seen, time::ms(WAIT_MS)))
		{
			defer snapshot.release();
			seen = snapshot.generation;
			if (check(&snapshot.value)) return true;
		}
	}
	return false;
}

fn bool succeeded(Task* task)
{
	if (catch task.wait(time::ms(TASK_MS)))
	{
		io::printfn("  task failed: %s | %s", error::last().message(), task.failure);
		return false;
	}
	return true;
}

fn void write_file(String path, String text)
{
	fs::write_text(path, text)!!;
}

fn int main(String[] args)
{
	if (args.len < 3)
	{
		io::printfn("usage: bluez_integration <bus address> <rfkill root>");
		return 2;
	}
	String address = args[1];
	String root = args[2];
	Bluetooth* bt = bluetooth::open(mem, { .backend = bluetooth::Backend.BLUEZ, .bus_address = address, .root = root }) ?? null;
	if (!bt)
	{
		io::printfn("FAIL open: %s", error::last().message());
		return 1;
	}
	defer bt.close();
	expect(bt.backend_name() == "bluez", "backend is bluez");
	expect(!bt.capability(bluetooth::Cap.PAIRING_PROMPTS).ok(), "pairing prompts are reported unavailable");
	stream::Reader{Event}* events = bt.subscribe() ?? null;
	defer { if (events != null) events.release(); }

	// Initial state: one controller, off, and the remembered headset with its battery and identity.
	Snapshot{State}* first = bt.wait_after(0, time::ms(5000)) ?? null;
	expect(first != null, "a first state is published");
	if (first)
	{
		defer first.release();
		State* s = &first.value;
		expect(s.adapters.len == 1 && !s.adapters[0].powered, "one controller, powered off");
		expect(s.adapters[0].address == "00:1A:7D:DA:71:13", "controller address");
		Device* h = device_at(s, HEADSET);
		expect(h != null, "remembered headset is known");
		if (h)
		{
			expect(h.display_name == "Bleu Headset" && h.icon == bluetooth::Icon.HEADPHONES, "headset name and icon from class");
			expect(h.battery.has_value && (float)h.battery.value == 0.75f, "headset battery 75 percent");
			expect(h.pnp.has_value && h.pnp.value.vendor == 0x1D6B, "headset vendor from modalias");
			expect(h.profiles.len == 2, "headset has two known profiles");
			expect(h.adapter == "00:1A:7D:DA:71:13", "headset belongs to the controller");
		}
	}

	// Power on.
	Task* power = bt.set_powered("", true) ?? null;
	expect(power != null && succeeded(power), "set_powered completes");
	if (power) power.release();
	expect(settle(bt, &dev_powered), "controller reports powered");

	// Discovery: devices appear with their RSSI while the scan runs.
	Task* scan = bt.start_discovery("", { .transport = bluetooth::Transport.BR_EDR, .duplicates = true }) ?? null;
	expect(scan != null && succeeded(scan), "start_discovery completes");
	if (scan) scan.release();
	expect(settle(bt, &keyboard_seen), "scan adds the keyboard");
	expect(settle(bt, &mouse_seen), "scan adds the mouse");

	// Pairing: success, a refused pairing, and a pairing cancelled by the caller.
	Task* pair_ok = bt.pair(HEADSET) ?? null;
	expect(pair_ok != null && succeeded(pair_ok), "pair with the headset succeeds");
	if (pair_ok) pair_ok.release();
	expect(settle(bt, &headset_paired), "headset is paired and bonded in the state");

	Task* pair_refused = bt.pair(MOUSE) ?? null;
	if (pair_refused)
	{
		expect(!succeeded(pair_refused) && pair_refused.failure == error::BACKEND_FAILURE, "refused pairing fails as BACKEND_FAILURE");
		pair_refused.release();
	}

	Task* pair_cancel = bt.pair(KEYBOARD) ?? null;
	Task* cancel = bt.cancel_pairing(KEYBOARD) ?? null;
	if (cancel)
	{
		expect(succeeded(cancel), "cancel_pairing completes");
		cancel.release();
	}
	if (pair_cancel)
	{
		expect(!succeeded(pair_cancel) && pair_cancel.failure == error::CANCELLED, "cancelled pairing ends CANCELLED");
		pair_cancel.release();
	}

	// Connections: the whole device, a refused connection, and the disconnect event with its reason.
	Task* connect = bt.connect(HEADSET) ?? null;
	expect(connect != null && succeeded(connect), "connect to the headset succeeds");
	if (connect) connect.release();
	expect(settle(bt, &headset_connected), "headset is connected in the state");

	Task* connect_phone = bt.connect(PHONE) ?? null;
	if (connect_phone)
	{
		expect(!succeeded(connect_phone), "connect to the phone is refused");
		connect_phone.release();
	}

	Task* profile = bt.connect_profile(HEADSET, bluetooth::Profile.A2DP_SINK) ?? null;
	expect(profile != null && succeeded(profile), "connect one profile of the headset");
	if (profile) profile.release();

	Task* disconnect = bt.disconnect(HEADSET) ?? null;
	expect(disconnect != null && succeeded(disconnect), "disconnect the headset succeeds");
	if (disconnect) disconnect.release();
	expect(settle(bt, &headset_disconnected), "headset is disconnected in the state");
	bool reason_seen = false;
	if (events)
	{
		for (int i = 0; i < EVENT_ROUNDS && !reason_seen; i++)
		{
			if (try packet = events.next(time::ms(WAIT_MS)))
			{
				defer packet.release();
				if (packet.value.kind == bluetooth::EventKind.DEVICE_DISCONNECTED && packet.value.address == HEADSET && packet.value.text == "org.bluez.Reason.Local")
				{
					reason_seen = true;
				}
			}
		}
	}
	expect(reason_seen, "disconnect event carries BlueZ's reason");

	// Trust, block, rename.
	Task* trust = bt.set_trusted(HEADSET, true) ?? null;
	if (trust) { expect(succeeded(trust), "set_trusted completes"); trust.release(); }
	Task* block = bt.set_blocked(HEADSET, true) ?? null;
	if (block) { expect(succeeded(block), "set_blocked completes"); block.release(); }
	Task* rename = bt.rename(HEADSET, "Renamed Headset") ?? null;
	if (rename) { expect(succeeded(rename), "rename completes"); rename.release(); }
	expect(settle(bt, &headset_managed), "trust, block and alias are in the state");

	// Remove: the mouse was scanned, and is forgotten.
	Task* remove = bt.remove(MOUSE) ?? null;
	if (remove) { expect(succeeded(remove), "remove completes"); remove.release(); }
	expect(settle(bt, &mouse_gone), "removed device leaves the state");

	// Kill switch: sysfs says blocked; the library reports it and does not clear it.
	write_file(string::tformat("%s/sys/class/rfkill/rfkill0/soft", root), "1");
	Task* refresh = bt.refresh() ?? null;
	if (refresh) { succeeded(refresh); refresh.release(); }
	expect(settle(bt, &dev_blocked), "rfkill soft block is reported as blocked");
	write_file(string::tformat("%s/sys/class/rfkill/rfkill0/soft", root), "0");
	refresh = bt.refresh() ?? null;
	if (refresh) { succeeded(refresh); refresh.release(); }
	expect(settle(bt, &dev_unblocked), "clearing the switch in sysfs is seen");

	// Pairing prompts are not offered on this backend: the request is refused at once.
	Task*? reply = bt.reply_pairing(1, true);
	if (catch err = reply)
	{
		expect(err == error::UNSUPPORTED, "reply_pairing is refused as UNSUPPORTED");
	}
	else
	{
		expect(false, "reply_pairing is refused as UNSUPPORTED");
	}

	if (failures == 0)
	{
		io::printfn("ALL CHECKS PASSED");
		return 0;
	}
	io::printfn("%d CHECK(S) FAILED", failures);
	return 1;
}
