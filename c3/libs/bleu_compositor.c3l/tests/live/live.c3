// Live driver for the fake compositors (run_live.sh). It goes through the same
// path a shell takes: detect from the environment, open, snapshot, wait on the
// event socket with the poller, apply events, and send actions. Its output lines
// are `key=value` so run_live.sh can check them.
module live;
import bleu::compositor, bleu::compositor::backend, bleu::compositor::connect, bleu::rt::wakeup, bleu::rt::poller, bleu::error, std::io;

// How long one wait for events may block, in microseconds.
const Duration WAIT_SLICE = (Duration)200_000;
// Waits after the snapshot; the fakes push their events within the first one.
const int EVENT_ROUNDS = 8;

fn String kind_name(compositor::Kind kind) @private
{
	switch (kind)
	{
		case compositor::Kind.HYPRLAND: return "HYPRLAND";
		case compositor::Kind.SWAY: return "SWAY";
		case compositor::Kind.I3: return "I3";
		case compositor::Kind.NIRI: return "NIRI";
		case compositor::Kind.RIVER: return "RIVER";
		case compositor::Kind.DWL: return "DWL";
		default: return "NONE";
	}
}

fn String focused_title(compositor::Model* model) @private
{
	for (sz i = 0; i < model.windows.len; i++)
	{
		if (model.windows[i].focused) return model.windows[i].title;
	}
	return "none";
}

fn String layout_name(compositor::Model* model) @private
{
	return model.layouts.current_name.len > 0 ? model.layouts.current_name : "none";
}

fn void summarize(String label, compositor::Model* model) @private
{
	io::printfn("%s windows=%d workspaces=%d outputs=%d focused=%s layout=%s", label, (int)model.windows.len, (int)model.workspaces.len, (int)model.outputs.len, focused_title(model), layout_name(model));
}

fn void report(String action, void? result) @private
{
	if (catch err = result)
	{
		io::printfn("%s=failed %s", action, error::last().message());
	}
	else
	{
		io::printfn("%s=ok", action);
	}
}

fn int main(int argc, char** argv)
{
	DynamicArenaAllocator arena;
	arena.init(mem, 65536);
	defer arena.free();
	Allocator allocator = &arena;

	compositor::Detection detection = compositor::detect(allocator);
	io::printfn("detect kind=%s reason=%s", kind_name(detection.kind), detection.reason);

	backend::Backend? opened = connect::open(allocator, detection);
	if (catch err = opened)
	{
		io::printfn("open=failed %s", error::last().message());
		return 1;
	}
	backend::Backend client = opened;
	io::printfn("open=ok");

	compositor::Model? snapshot = client.snapshot(allocator);
	if (catch err = snapshot)
	{
		io::printfn("snapshot=failed %s", error::last().message());
		return 1;
	}
	compositor::Model model = snapshot;
	summarize("snapshot", &model);

	wakeup::Wakeup wake;
	wake.init()!!;
	defer wake.close();
	poller::Poller loop;
	loop.init(mem, &wake, 4)!!;
	defer loop.free();
	poller::Interest reading;
	reading.readable = true;
	loop.add({ .handle = client.event_handle(), .interest = reading, .tag = 1 })!!;

	for (int round = 0; round < EVENT_ROUNDS; round++)
	{
		if (catch err = loop.wait(WAIT_SLICE))
		{
			// Nothing arrived in this slice: keep waiting.
			continue;
		}
		if (catch err = client.read_events(&model, allocator))
		{
			io::printfn("read_events=failed %s", error::last().message());
			return 2;
		}
		io::printfn("round=%d", round);
	}
	summarize("after", &model);
	io::printfn("layout_index=%d", model.layouts.current.has_value ? (int)model.layouts.current.value : -1);

	compositor::Model copy = model.clone(allocator);
	io::printfn("clone windows=%d", (int)copy.windows.len);

	switch (detection.kind)
	{
		case compositor::Kind.HYPRLAND:
			report("focus_window", client.focus_window("0x55d1c0a4e2b0"));
			report("switch_workspace", client.switch_workspace("2"));
			report("move_window", client.move_window("0x55d1c0a4e2b0", "2"));
			report("set_layout", client.set_layout(1));
			report("toggle_floating", client.toggle_floating("0x55d1c0a4e2b0"));
			report("toggle_fullscreen", client.toggle_fullscreen("0x55d1c0a4e2b0"));
			report("close_window", client.close_window("0x55d1c0a4e2b0"));
		case compositor::Kind.SWAY:
		case compositor::Kind.I3:
			report("focus_window", client.focus_window("11"));
			report("switch_workspace", client.switch_workspace("2:web"));
			report("move_window", client.move_window("11", "2:web"));
			report("set_layout", client.set_layout(1));
			report("toggle_floating", client.toggle_floating("11"));
			report("toggle_fullscreen", client.toggle_fullscreen("11"));
			report("close_window", client.close_window("11"));
		case compositor::Kind.NIRI:
			report("focus_window", client.focus_window("7"));
			report("switch_workspace", client.switch_workspace("3"));
			report("move_window", client.move_window("7", "3"));
			report("set_layout", client.set_layout(1));
			report("toggle_floating", client.toggle_floating("7"));
			report("toggle_fullscreen", client.toggle_fullscreen("7"));
			report("close_window", client.close_window("7"));
			report("focus_window_refused", client.focus_window("99"));
		default:
			io::printfn("actions=skipped");
	}
	report("focus_window_not_an_id", client.focus_window("not an id"));
	client.close();
	io::printfn("closed");
	return 0;
}
