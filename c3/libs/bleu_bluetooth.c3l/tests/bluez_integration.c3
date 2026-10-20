// Drives the BlueZ backend through the public API against tests/mock_bluez.py.
// Run by tests/run.sh with two arguments: the bus address and an rfkill root.
// Prints one PASS or FAIL line per check and exits non-zero when any check fails.
module bluez_integration @feat(LINUX);
import std::io, std::thread, std::time, bleu::bluetooth, bleu::error, bleu::observe, bleu::operation, bleu::rt::fs, bleu::stream;

alias State = bluetooth::State;
alias Device = bluetooth::Device;
alias Task = bluetooth::Task;
alias Bluetooth = bluetooth::Bluetooth;
alias Event = bluetooth::Event;
alias Phase = operation::Phase{bluetooth::Done};

const String HEADSET   = "AA:BB:CC:DD:EE:01";
const String MOUSE     = "AA:BB:CC:DD:EE:02";
const String KEYBOARD  = "AA:BB:CC:DD:EE:03";
const String PHONE     = "AA:BB:CC:DD:EE:04";
const ulong WAIT_MS    = 200;
const int WAIT_ROUNDS  = 50;
const ulong TASK_MS    = 10000;
const int EVENT_ROUNDS = 25;
// The pairing deadline of the completion checks: short, so that an unanswered pairing ends quickly.
const ulong PAIRING_MS = 2000;
// How long a check waits for a task that must end by its deadline.
const ulong FINISH_MS  = 6000;
// Requests posted at once when a service is stopped, and how many times the stop is repeated.
const int BURST        = 50;
const int BURST_ROUNDS = 20;

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

// What the test saw of one pairing prompt.
struct PromptSeen
{
	bool found;
	ulong id;
	bool has_passkey;
	uint passkey;
}

// The first pairing request of `kind` for `device`, within the event budget.
fn PromptSeen wait_for_prompt(stream::Reader{Event}* events, bluetooth::PromptKind kind, String device)
{
	PromptSeen seen;
	if (events == null) return seen;
	for (int i = 0; i < EVENT_ROUNDS && !seen.found; i++)
	{
		if (try packet = events.next(time::ms(WAIT_MS)))
		{
			defer packet.release();
			Event* event = &packet.value;
			if (event.kind == bluetooth::EventKind.PAIRING_REQUEST && event.request.kind == kind
				&& event.request.device == device)
			{
				seen = {
					.found = true,
					.id = event.request.id,
					.has_passkey = event.request.passkey.has_value,
					.passkey = event.request.passkey.value
				};
			}
		}
	}
	return seen;
}

// Answers a prompt and says whether the answer itself was accepted.
fn bool answer(Bluetooth* bt, ulong id, bool accept, String secret)
{
	Task* reply = bt.reply_pairing(id, accept, secret) ?? null;
	if (reply == null) return false;
	defer reply.release();
	return succeeded(reply);
}

// True when the task is still pending after a short wait.
fn bool catch_timeout(Task* task)
{
	if (catch err = task.wait(time::ms(WAIT_MS))) return err == TIMEOUT;
	return false;
}

fn int main(String[] args)
{
	if (args.len < 4)
	{
		io::printfn("usage: bluez_integration <bus address> <rfkill root> <fail-tree marker file>");
		return 2;
	}
	String address = args[1];
	String root    = args[2];
	String fail_tree = args[3];
	Bluetooth* bt  = bluetooth::open(
		mem,
		{ .backend = bluetooth::Backend.BLUEZ, .bus_address = address, .root = root }
	) ?? null;
	if (!bt)
	{
		io::printfn("FAIL open: %s", error::last().message());
		return 1;
	}
	defer bt.close();
	expect(bt.backend_name() == "bluez", "backend is bluez");
	expect(bt.capability(bluetooth::Cap.PAIRING_PROMPTS).ok(), "pairing prompts are offered");
	stream::Reader{Event}* events = bt.subscribe() ?? null;
	defer
	{
		if (events != null) events.release();
	}

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
			expect(
				h.display_name == "Bleu Headset" && h.icon == bluetooth::Icon.HEADPHONES,
				"headset name and icon from class"
			);
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

	// Pairing through the agent: the user confirms a number, types a PIN, and refuses a passkey.
	// A keyboard pairing is cancelled by the caller instead.
	Task* pair_ok      = bt.pair(HEADSET) ?? null;
	PromptSeen confirm = wait_for_prompt(events, bluetooth::PromptKind.CONFIRM, HEADSET);
	expect(confirm.found && confirm.has_passkey && confirm.passkey == 123456, "headset asks to confirm 123456");
	expect(answer(bt, confirm.id, true, ""), "confirming the number is accepted");
	expect(pair_ok != null && succeeded(pair_ok), "pair with the headset succeeds once confirmed");
	if (pair_ok) pair_ok.release();
	expect(settle(bt, &headset_paired), "headset is paired and bonded in the state");

	Task* pair_pin = bt.pair(MOUSE) ?? null;
	PromptSeen pin = wait_for_prompt(events, bluetooth::PromptKind.PIN, MOUSE);
	expect(pin.found, "mouse asks for a PIN");
	Task* empty_pin = bt.reply_pairing(pin.id, true, "") ?? null;
	if (empty_pin != null)
	{
		expect(
			!succeeded(empty_pin) && empty_pin.failure == error::INVALID_ARGUMENT,
			"an empty PIN is refused, not sent"
		);
		empty_pin.release();
	}
	if (pair_pin != null)
	{
		expect(catch_timeout(pair_pin), "pairing waits for the user's PIN");
	}
	expect(answer(bt, pin.id, true, "4321"), "typing the PIN is accepted");
	expect(pair_pin != null && succeeded(pair_pin), "pair with the mouse succeeds with the typed PIN");
	if (pair_pin) pair_pin.release();

	Task* pair_refused = bt.pair(PHONE) ?? null;
	PromptSeen passkey = wait_for_prompt(events, bluetooth::PromptKind.PASSKEY_ENTRY, PHONE);
	expect(passkey.found, "phone asks for a passkey");
	expect(answer(bt, passkey.id, false, ""), "refusing the passkey is accepted");
	if (pair_refused != null)
	{
		expect(
			!succeeded(pair_refused) && pair_refused.failure == error::BACKEND_FAILURE,
			"refused pairing fails as BACKEND_FAILURE"
		);
		pair_refused.release();
	}

	Task* unknown = bt.reply_pairing(999999, true, "") ?? null;
	if (unknown != null)
	{
		expect(
			!succeeded(unknown) && unknown.failure == error::INVALID_STATE,
			"an answer to no waiting prompt is INVALID_STATE"
		);
		unknown.release();
	}

	Task* pair_cancel = bt.pair(KEYBOARD) ?? null;
	Task* cancel      = bt.cancel_pairing(KEYBOARD) ?? null;
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
				if (packet.value.kind == bluetooth::EventKind.DEVICE_DISCONNECTED && packet.value.address == HEADSET
					&& packet.value.text == "org.bluez.Reason.Local")
				{
					reason_seen = true;
				}
			}
		}
	}
	expect(reason_seen, "disconnect event carries BlueZ's reason");

	// Trust, block, rename.
	Task* trust = bt.set_trusted(HEADSET, true) ?? null;
	if (trust)
	{
		expect(succeeded(trust), "set_trusted completes");
		trust.release();
	}
	Task* block = bt.set_blocked(HEADSET, true) ?? null;
	if (block)
	{
		expect(succeeded(block), "set_blocked completes");
		block.release();
	}
	Task* rename = bt.rename(HEADSET, "Renamed Headset") ?? null;
	if (rename)
	{
		expect(succeeded(rename), "rename completes");
		rename.release();
	}
	expect(settle(bt, &headset_managed), "trust, block and alias are in the state");

	// Remove: the mouse was scanned, and is forgotten.
	Task* remove = bt.remove(MOUSE) ?? null;
	if (remove)
	{
		expect(succeeded(remove), "remove completes");
		remove.release();
	}
	expect(settle(bt, &mouse_gone), "removed device leaves the state");

	// Kill switch: sysfs says blocked; the library reports it and does not clear it.
	write_file(string::tformat("%s/sys/class/rfkill/rfkill0/soft", root), "1");
	Task* refresh = bt.refresh() ?? null;
	if (refresh)
	{
		succeeded(refresh);
		refresh.release();
	}
	expect(settle(bt, &dev_blocked), "rfkill soft block is reported as blocked");
	write_file(string::tformat("%s/sys/class/rfkill/rfkill0/soft", root), "0");
	refresh = bt.refresh() ?? null;
	if (refresh)
	{
		succeeded(refresh);
		refresh.release();
	}
	expect(settle(bt, &dev_unblocked), "clearing the switch in sysfs is seen");

	// A failed read of BlueZ's objects keeps the last state: the headset stays known.
	write_file(fail_tree, "1");
	Task* failing = bt.refresh() ?? null;
	if (failing)
	{
		succeeded(failing);
		failing.release();
	}
	thread::sleep(time::ms(WAIT_MS * 3))!!;
	Snapshot{State}* kept = bt.latest() ?? null;
	if (kept)
	{
		defer kept.release();
		expect(has_device(&kept.value, HEADSET) && kept.value.adapters.len == 1, "a failed tree read keeps the last state");
	}
	else
	{
		expect(false, "a failed tree read keeps the last state");
	}
	write_file(fail_tree, "0");

	deadline_checks(address, root);
	stopping_completes_queued(address, root);

	if (failures == 0)
	{
		io::printfn("ALL CHECKS PASSED");
		return 0;
	}
	io::printfn("%d CHECK(S) FAILED", failures);
	return 1;
}
// True once the task has reached a terminal phase.
fn bool is_done(Task* task)
{
	Phase phase = task.phase();
	return phase == Phase.SUCCEEDED || phase == Phase.FAILED || phase == Phase.CANCELLED;
}

// Waits up to `ms` for the task, and says whether it has ended by then.
fn bool ends_within(Task* task, ulong ms)
{
	if (catch task.wait(time::ms((long)ms))) {}
	return is_done(task);
}

// True when the event stream carries the end of prompt `id`.
fn bool prompt_ended(stream::Reader{Event}* events, ulong id)
{
	for (int i = 0; i < EVENT_ROUNDS; i++)
	{
		if (try packet = events.next(time::ms(WAIT_MS)))
		{
			defer packet.release();
			if (packet.value.kind == bluetooth::EventKind.PAIRING_ENDED && packet.value.request.id == id) return true;
		}
	}
	return false;
}

// Pairings with a short deadline, against the mock's behaviour. Each check fails on the code before the
// deadline and completion fixes: a tolerated AlreadyExists must not make a later timeout a success (B1); a
// pairing that is never answered must end at its deadline while nothing else wakes the worker (B3); its
// unanswered prompt must close with it, so that a late answer is refused (B4, B5).
fn void deadline_checks(String address, String root)
{
	Bluetooth* bt = bluetooth::open(
		mem,
		{
			.backend = bluetooth::Backend.BLUEZ,
			.bus_address = address,
			.root = root,
			.pairing_timeout = time::ms(PAIRING_MS),
		}
	) ?? null;
	if (!bt)
	{
		expect(false, "open with a short pairing timeout");
		return;
	}
	defer bt.close();
	stream::Reader{Event}* events = bt.subscribe() ?? null;
	if (!events)
	{
		expect(false, "subscribe for the deadline checks");
		return;
	}
	defer events.release();

	// The headset is already paired, so BlueZ answers AlreadyExists: that is success.
	Task* again = bt.pair(HEADSET) ?? null;
	if (again)
	{
		expect(succeeded(again), "pairing a paired headset again is success");
		again.release();
	}

	// The keyboard's pairing waits for a CancelPairing that never comes: its deadline ends it.
	Task* hang = bt.pair(KEYBOARD) ?? null;
	if (hang)
	{
		defer hang.release();
		expect(
			ends_within(hang, FINISH_MS) && hang.failure == TIMEOUT,
			"an unanswered pairing ends at its deadline while the worker is idle"
		);
	}

	// The phone asks for a passkey that nobody answers: the pairing ends, and its prompt closes with it.
	Task* phone = bt.pair(PHONE) ?? null;
	if (phone)
	{
		defer phone.release();
		PromptSeen prompt = wait_for_prompt(events, bluetooth::PromptKind.PASSKEY_ENTRY, PHONE);
		expect(prompt.found, "phone asks for a passkey");
		expect(
			ends_within(phone, FINISH_MS) && phone.failure == TIMEOUT,
			"an unanswered pairing ends at its deadline"
		);
		expect(prompt_ended(events, prompt.id), "the prompt of an ended pairing is closed");
		Task* late = bt.reply_pairing(prompt.id, true, "123456") ?? null;
		if (late)
		{
			defer late.release();
			expect(!succeeded(late) && late.failure == error::INVALID_STATE, "an answer after the deadline is refused");
		}
	}
}

// Stopping a service with requests still queued completes every one of them: none is left waiting
// forever. Each round posts a burst and stops at once, so some requests are still queued.
fn void stopping_completes_queued(String address, String root)
{
	int unfinished = 0;
	int posted     = 0;
	for (int round = 0; round < BURST_ROUNDS; round++)
	{
		Bluetooth* bt = bluetooth::open(
			mem,
			{ .backend = bluetooth::Backend.BLUEZ, .bus_address = address, .root = root }
		) ?? null;
		if (!bt) break;
		Task*[BURST] tasks;
		usz count = 0;
		for (int i = 0; i < BURST; i++)
		{
			if (try task = bt.set_discoverable("", i % 2 == 0))
			{
				tasks[count++] = task;
			}
		}
		bt.close();
		for (usz i = 0; i < count; i++)
		{
			posted++;
			if (!is_done(tasks[i])) unfinished++;
			tasks[i].release();
		}
	}
	expect(posted > 0 && unfinished == 0, "every request queued at stop is completed");
}
