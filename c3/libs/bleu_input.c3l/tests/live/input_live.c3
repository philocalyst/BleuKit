// Live driver for the input service (run_compositor.sh and run_locale1.sh). It goes through the path a
// shell takes: open (the backend is chosen from the environment), read the first snapshot, list the
// capabilities, switch layouts, and watch the events and snapshots that follow. Output lines are
// `key=value` so the scripts can check them.
// 
// Environment: INPUT_BACKEND (optional) forces a backend: COMPOSITOR, LOCALE1. INPUT_SWITCH_TO (optional)
// is the layout id to switch to; "next" uses the service's next(). INPUT_WATCH_MS is how long the driver
// watches for changes after the switch.
module input_live;
import bleu::input, bleu::availability, bleu::error, bleu::stream, bleu::observe, std::io, std::time, std::os::env;

const Duration POLL       = (Duration)200_000;
const Duration FIRST_WAIT = (Duration)3_000_000;
const Duration EVENT_WAIT = (Duration)100_000;

fn void describe(Snapshot{State}* snapshot) @local
{
	State* state = &snapshot.value;
	io::printfn("layouts=%d can_switch=%s", (int)state.layouts.len, state.can_switch ? "yes" : "no");
	foreach (i, &layout : state.layouts)
	{
		io::printfn(
			"layout index=%d id=%s name=%s short=%s language=%s variant=%s",
			(int)i,
			layout.id,
			layout.name,
			layout.short_code,
			layout.language,
			layout.variant
		);
	}
	if (state.current.has_value)
	{
		io::printfn("current=%d", (int)state.current.value);
	}
	else
	{
		io::printfn("current=none");
	}
}

fn String refusal_name(fault err) @local
{
	if (err == error::UNSUPPORTED) return "UNSUPPORTED";
	if (err == error::INVALID_STATE) return "INVALID_STATE";
	if (err == NOT_FOUND) return "NOT_FOUND";
	if (err == error::UNAVAILABLE) return "UNAVAILABLE";
	return "OTHER";
}

// "next" asks the service for the next layout; any other target is a layout id.
fn SwitchOperation*? request_switch(Input* input, String target) @local
{
	if (target == "next") return input.next();
	return input.switch_to(target);
}

fn void capability_line(Input* input, Cap cap, String label) @local
{
	Availability availability = input.capability(cap);
	io::printfn("cap %s=%s reason=%d", label, availability.ok() ? "yes" : "no", (int)availability.reason);
}

fn int main()
{
	Options options = { .poll = POLL };
	if (try name = env::tget_var("INPUT_BACKEND"))
	{
		if (name == "COMPOSITOR") options.backend = Backend.COMPOSITOR;
		if (name == "LOCALE1") options.backend = Backend.LOCALE1;
	}
	Input*? opened = input::open(mem, options);
	if (catch err = opened)
	{
		io::printfn("open=failed %s", refusal_name(err));
		return 1;
	}
	Input* input = opened;
	defer input.close();
	io::printfn("open=ok backend=%s", input.backend_name());
	capability_line(input, Cap.LIST, "LIST");
	capability_line(input, Cap.CURRENT, "CURRENT");
	capability_line(input, Cap.SWITCH, "SWITCH");
	capability_line(input, Cap.EVENTS, "EVENTS");

	Snapshot{State}*? first = input.wait_after(0, FIRST_WAIT);
	if (catch err = first)
	{
		io::printfn("snapshot=failed %s", error::last().message());
		return 1;
	}
	Snapshot{State}* snapshot = first;
	describe(snapshot);
	ulong seen = snapshot.generation;
	snapshot.release();

	Reader{Event}*? subscribed = input.subscribe();
	if (catch err = subscribed)
	{
		io::printfn("subscribe=failed %s", error::last().message());
		return 1;
	}
	Reader{Event}* reader = subscribed;
	defer reader.release();

	// A switch to an id that is not in the state is refused before it reaches the backend.
	if (catch err = input.switch_to("no-such-layout"))
	{
		io::printfn("switch_unknown=refused %s", refusal_name(err));
	}
	else
	{
		io::printfn("switch_unknown=accepted");
	}

	String target = env::tget_var("INPUT_SWITCH_TO") ?? "";
	if (target.len > 0)
	{
		SwitchOperation*? requested = request_switch(input, target);
		if (catch err = requested)
		{
			io::printfn("switch=refused %s", refusal_name(err));
		}
		else
		{
			SwitchOperation* operation = requested;
			defer operation.release();
			SwitchOutcome? outcome = operation.wait(time::sec(2));
			if (catch failure = outcome)
			{
				io::printfn("switch=failed %s", refusal_name(failure));
			}
			else
			{
				SwitchOutcome done = outcome;
				io::printfn("switch=done outcome=%s", done == SwitchOutcome.ACKNOWLEDGED ? "ACKNOWLEDGED" : "QUEUED");
			}
		}
	}

	// Watch for the events and snapshots the backend reports after the switch.
	for (int round = 0; round < 15; round++)
	{
		while (try packet = reader.next(EVENT_WAIT))
		{
			io::printfn("event kind=%d layout=%s", (int)packet.value.kind, packet.value.layout_id);
			packet.release();
		}
		if (try next = input.wait_after(seen, EVENT_WAIT))
		{
			seen = next.generation;
			io::printfn("changed:");
			describe(next);
			next.release();
		}
	}
	io::printfn("done");
	return 0;
}