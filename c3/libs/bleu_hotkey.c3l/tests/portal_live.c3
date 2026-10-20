// Live tests of the portal backend against mock_portal.py. run.sh starts the private session bus and
// the mock, and sets BLEU_HOTKEY_CONTROL to the control file that `command` appends to.
module bleu::hotkey::portal_live_test @feat(LINUX);
import std::os::env, std::time, std::io, std::thread, bleu::availability, bleu::error, bleu::hotkey, bleu::hotkey::keys, bleu::observe, bleu::rt::fs, bleu::stream;

// Every control line written so far; the mock applies them in order.
String[32] script;
usz script_len = 0;

// Append one command to the mock's control file.
fn void command(String line) @local
{
	script[script_len++] = line;
	DString text;
	text.init(mem);
	defer text.free();
	for (usz i = 0; i < script_len; i++)
	{
		text.append(script[i]);
		text.append_char('\n');
	}
	fs::write_text(env::tget_var("BLEU_HOTKEY_CONTROL")!!, text.str_view())!!;
	// The mock polls the control file every 50 ms: give it time to apply the line before the next call.
	thread::sleep(time::ms(200))!!;
}

// The state of the binding `id`, or NOT_FOUND.
fn BindingState? state_of(State* state, String id)
{
	foreach (binding : state.bindings)
	{
		if (binding.id == id) return binding.state;
	}
	return NOT_FOUND~;
}

// The newest state in which binding `id` has state `want` (and trigger text `trigger`, when given).
// The portal answers on the worker thread, so this waits for the publication that shows it.
fn Snapshot{State}*? settle(Hotkey* hotkeys, String id, BindingState want, String trigger = "")
{
	ulong seen = 0;
	for (usz attempt = 0; attempt < 60; attempt++)
	{
		if (try snapshot = hotkeys.wait_after(seen, time::ms(100)))
		{
			seen = snapshot.generation;
			foreach (binding : snapshot.value.bindings)
			{
				if (binding.id == id && binding.state == want
					&& (trigger == "" || binding.trigger == trigger)) return snapshot;
			}
			snapshot.release();
		}
	}
	return TIMEOUT~;
}

// Read one press or release and check it.
fn void expect_press(stream::Reader{Event}* presses, EventKind kind, String id, ulong platform_time, String token)
{
	Snapshot{Event}* packet = presses.next(time::ms(5000))!!;
	defer packet.release();
	Event event = packet.value;
	assert(event.kind == kind, "kind");
	assert(event.id == id, "id");
	assert(event.platform_time.has_value && event.platform_time.value == platform_time, "the portal's timestamp");
	assert(event.activation_token == token, "the activation token, when the portal gave one");
	assert((ulong)event.at > 0, "receipt time is set");
}

fn void the_portal_binds_reports_and_follows() @test
{
	Hotkey* hotkeys = hotkey::open(mem, { .backend = PORTAL })!!;
	defer hotkeys.close();
	assert(hotkeys.backend_name() == "portal");
	assert(hotkeys.capability(Cap.REGISTER).ok(), "the portal can bind shortcuts");
	assert(hotkeys.capability(Cap.CONFLICT_REPORT).reason == availability::Reason.UNSUPPORTED_BACKEND);
	stream::Reader{Event}* presses = hotkeys.subscribe()!!;
	defer presses.release();

	// A shortcut the portal binds: BOUND, with the trigger text it reports (the mock echoes preferred_trigger).
	Chord toggle_chord = hotkey::parse_chord("Ctrl+Alt+T")!!;
	Task* toggle       = hotkeys.register("toggle", "Show or hide the bar", toggle_chord)!!;
	Binding bound      = toggle.wait(time::ms(10000))!!;
	assert(bound.state == BOUND, "the portal bound it");
	assert(bound.trigger == "CTRL+ALT+t", "the trigger the portal reports");
	toggle.release();
	Snapshot{State}* first = settle(hotkeys, "toggle", BOUND)!!;
	assert(first.value.portal_version == 2, "the interface version is read");
	assert(first.value.registration.ok(), "registration is available");
	first.release();

	// Presses and releases arrive as events, with the portal's timestamp and the activation token.
	command("activate toggle 1234 token-1");
	expect_press(presses, PRESSED, "toggle", 1234, "token-1");
	command("deactivate toggle 1300");
	expect_press(presses, RELEASED, "toggle", 1300, "");

	// The portal refuses one shortcut: that registration is REFUSED, the others stay bound.
	command("refuse bar");
	Task* bar       = hotkeys.register("bar", "Second shortcut", hotkey::parse_chord("Ctrl+Shift+B")!!)!!;
	Binding refused = bar.wait(time::ms(10000))!!;
	assert(refused.state == REFUSED, "the portal refused it");
	bar.release();
	Snapshot{State}* kept = settle(hotkeys, "toggle", BOUND)!!;
	kept.release();

	// Removing a shortcut returns the binding that was removed.
	Task* removal   = hotkeys.unregister("bar")!!;
	Binding removed = removal.wait(time::ms(10000))!!;
	assert(removed.id == "bar" && removed.state == REFUSED, "the removed binding comes back");
	removal.release();

	// Unknown ids and duplicate ids fail with their own errors.
	Task* missing = hotkeys.unregister("nope")!!;
	assert(@catch(missing.wait(time::ms(10000))) == NOT_FOUND, "unknown id");
	missing.release();
	Task* again = hotkeys.register("toggle", "Again", toggle_chord)!!;
	assert(@catch(again.wait(time::ms(10000))) == error::INVALID_STATE, "duplicate id");
	again.release();

	// ShortcutsChanged updates the trigger text the portal shows.
	command("changed toggle CTRL+ALT+Return");
	Snapshot{State}* moved = settle(hotkeys, "toggle", BOUND, "CTRL+ALT+Return")!!;
	moved.release();

	// A declined dialog fails the request, and the next round binds everything again.
	command("mode cancel");
	Task* late = hotkeys.register("late", "Declined", hotkey::parse_chord("Ctrl+Alt+L")!!)!!;
	assert(@catch(late.wait(time::ms(10000))) == error::CANCELLED, "the user declined");
	late.release();
	command("mode ok");
	Task* after  = hotkeys.register("after", "Back to normal", hotkey::parse_chord("Ctrl+Alt+A")!!)!!;
	Binding back = after.wait(time::ms(10000))!!;
	assert(back.state == BOUND, "the next round binds it");
	after.release();
	Snapshot{State}* restored = settle(hotkeys, "toggle", BOUND)!!;
	restored.release();

	// Response 2: the desktop does not bind shortcuts. The request fails, the registration says why,
	// and later requests are refused with UNSUPPORTED.
	command("mode other");
	Task* broken = hotkeys.register("broken", "Unsupported", hotkey::parse_chord("Ctrl+Alt+X")!!)!!;
	assert(@catch(broken.wait(time::ms(10000))) == error::UNAVAILABLE, "response 2 fails the request");
	broken.release();
	Snapshot{State}* unsupported = settle_registration(hotkeys)!!;
	assert(unsupported.value.registration.reason == availability::Reason.UNSUPPORTED_BACKEND);
	unsupported.release();
	Task* refused_now = hotkeys.register("again-later", "Refused", hotkey::parse_chord("Ctrl+Alt+Y")!!)!!;
	assert(@catch(refused_now.wait(time::ms(10000))) == error::UNSUPPORTED, "refused while the desktop has no support");
	refused_now.release();
}

// The newest state whose registration is not available: waits for the worker to publish it.
fn Snapshot{State}*? settle_registration(Hotkey* hotkeys)
{
	ulong seen = 0;
	for (usz attempt = 0; attempt < 60; attempt++)
	{
		if (try snapshot = hotkeys.wait_after(seen, time::ms(100)))
		{
			seen = snapshot.generation;
			if (!snapshot.value.registration.ok()) return snapshot;
			snapshot.release();
		}
	}
	return TIMEOUT~;
}