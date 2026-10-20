// Live driver for the fake compositors (run_live.sh). It goes through the same
// path a shell takes: detect from the environment, open, snapshot, wait on the
// event socket with the poller, apply events, and send actions. Its output lines
// are `key=value` so run_live.sh can check them.
module live;
import bleu::compositor, bleu::compositor::backend, bleu::compositor::connect, bleu::rt::wakeup, bleu::rt::poller, bleu::error, std::io, std::time;

// How long one wait for events may block, in microseconds.
const Duration WAIT_SLICE = (Duration)200_000;
// Waits after the snapshot; the fakes push their events within the first one.
const int EVENT_ROUNDS    = 8;

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
	io::printfn(
		"%s windows=%d workspaces=%d outputs=%d focused=%s layout=%s",
		label,
		(int)model.windows.len,
		(int)model.workspaces.len,
		(int)model.outputs.len,
		focused_title(model),
		layout_name(model)
	);
}

fn void report_ok(String action) @private
{
	io::printfn("%s=ok", action);
}

fn void report_failed(String action, fault failure) @private
{
	io::printfn("%s=failed %s (%s)", action, error::last().message(), failure);
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
			if (catch err = client.focus_window("0x55d1c0a4e2b0"))
			{
				report_failed("focus_window", err);
			}
			else
			{
				report_ok("focus_window");
			}
			if (catch err = client.switch_workspace("2"))
			{
				report_failed("switch_workspace", err);
			}
			else
			{
				report_ok("switch_workspace");
			}
			if (catch err = client.move_window("0x55d1c0a4e2b0", "2"))
			{
				report_failed("move_window", err);
			}
			else
			{
				report_ok("move_window");
			}
			if (catch err = client.set_layout(1))
			{
				report_failed("set_layout", err);
			}
			else
			{
				report_ok("set_layout");
			}
			if (catch err = client.toggle_floating("0x55d1c0a4e2b0"))
			{
				report_failed("toggle_floating", err);
			}
			else
			{
				report_ok("toggle_floating");
			}
			if (catch err = client.toggle_fullscreen("0x55d1c0a4e2b0"))
			{
				report_failed("toggle_fullscreen", err);
			}
			else
			{
				report_ok("toggle_fullscreen");
			}
			if (catch err = client.close_window("0x55d1c0a4e2b0"))
			{
				report_failed("close_window", err);
			}
			else
			{
				report_ok("close_window");
			}
		case compositor::Kind.SWAY:
		case compositor::Kind.I3:
			if (catch err = client.focus_window("11"))
			{
				report_failed("focus_window", err);
			}
			else
			{
				report_ok("focus_window");
			}
			if (catch err = client.switch_workspace("2:web"))
			{
				report_failed("switch_workspace", err);
			}
			else
			{
				report_ok("switch_workspace");
			}
			if (catch err = client.move_window("11", "2:web"))
			{
				report_failed("move_window", err);
			}
			else
			{
				report_ok("move_window");
			}
			if (catch err = client.set_layout(1))
			{
				report_failed("set_layout", err);
			}
			else
			{
				report_ok("set_layout");
			}
			if (catch err = client.toggle_floating("11"))
			{
				report_failed("toggle_floating", err);
			}
			else
			{
				report_ok("toggle_floating");
			}
			if (catch err = client.toggle_fullscreen("11"))
			{
				report_failed("toggle_fullscreen", err);
			}
			else
			{
				report_ok("toggle_fullscreen");
			}
			if (catch err = client.close_window("11"))
			{
				report_failed("close_window", err);
			}
			else
			{
				report_ok("close_window");
			}
		case compositor::Kind.NIRI:
			if (catch err = client.focus_window("7"))
			{
				report_failed("focus_window", err);
			}
			else
			{
				report_ok("focus_window");
			}
			if (catch err = client.switch_workspace("3"))
			{
				report_failed("switch_workspace", err);
			}
			else
			{
				report_ok("switch_workspace");
			}
			if (catch err = client.move_window("7", "3"))
			{
				report_failed("move_window", err);
			}
			else
			{
				report_ok("move_window");
			}
			if (catch err = client.set_layout(1))
			{
				report_failed("set_layout", err);
			}
			else
			{
				report_ok("set_layout");
			}
			if (catch err = client.toggle_floating("7"))
			{
				report_failed("toggle_floating", err);
			}
			else
			{
				report_ok("toggle_floating");
			}
			if (catch err = client.toggle_fullscreen("7"))
			{
				report_failed("toggle_fullscreen", err);
			}
			else
			{
				report_ok("toggle_fullscreen");
			}
			if (catch err = client.close_window("7"))
			{
				report_failed("close_window", err);
			}
			else
			{
				report_ok("close_window");
			}
			if (catch err = client.focus_window("99"))
			{
				report_failed("focus_window_refused", err);
			}
			else
			{
				report_ok("focus_window_refused");
			}
		default:
			io::printfn("actions=skipped");
	}
	if (catch err = client.focus_window("not an id"))
	{
		report_failed("focus_window_not_an_id", err);
	}
	else
	{
		report_ok("focus_window_not_an_id");
	}
	client.close();
	io::printfn("closed");
	return 0;
}