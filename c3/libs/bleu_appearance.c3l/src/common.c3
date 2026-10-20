<*
 Machinery every backend of the appearance service shares: which parts of the
 state changed, publishing with events, settling requests, and copies.
*>
module bleu::appearance;
import bleu::equal, bleu::error, bleu::observe, bleu::operation, bleu::stream, bleu::rt::worker;

alias StateSnapshot = Snapshot{State};

<* The parts of `State` that differ between two states. *>
struct Changes
{
	bool color_scheme;
	bool accent;
	bool accessibility;
	bool desktop;
	bool wallpaper;
}

<* Compare two states part by part. *>
fn Changes changes_between(State* before, State* after)
{
	return {
		.color_scheme = before.color_scheme != after.color_scheme,
		.accent = !equal::deep(before.accent, after.accent),
		.accessibility = before.contrast != after.contrast || before.reduced_motion != after.reduced_motion
			|| before.reduced_transparency != after.reduced_transparency,
		.desktop = before.font_name != after.font_name || !equal::deep(
			before.text_scale,
			after.text_scale
		) || before.icon_theme
			!= after.icon_theme || before.gtk_theme
				!= after.gtk_theme || before.cursor_theme
					!= after.cursor_theme || before.clock_format != after.clock_format,
		.wallpaper = !equal::deep(before.wallpapers, after.wallpapers),
	};
}

<*
 Publish `snapshot` unless it equals the latest one, then emit one event per
 part that changed. The first state emits nothing. Consumes the caller's reference.
*>
fn void publish(AppearanceHub* hub, StateSnapshot* snapshot)
{
	if (try current = hub.latest())
	{
		defer current.release();
		if (equal::deep(current.value, snapshot.value))
		{
			snapshot.release();
			return;
		}
		Changes changed = changes_between(&current.value, &snapshot.value);
		hub.publish(snapshot);
		emit_changes(hub, changed);
		return;
	}
	hub.publish(snapshot);
}

fn void emit_changes(AppearanceHub* hub, Changes changed)
{
	if (changed.color_scheme) emit(hub, COLOR_SCHEME);
	if (changed.accent) emit(hub, ACCENT);
	if (changed.accessibility) emit(hub, ACCESSIBILITY);
	if (changed.desktop) emit(hub, DESKTOP);
	if (changed.wallpaper) emit(hub, WALLPAPER);
}

fn void emit(AppearanceHub* hub, EventKind kind)
{
	Packet{Event}* packet = hub.emit_begin();
	packet.value = { .kind = kind };
	hub.emit(packet);
}

<* Finish a request successfully and drop the worker's reference to it. *>
fn void succeed_command(Command* command)
{
	(void)command.op.succeed(true);
	command.op.release();
}

<* Finish a request with `failure` and drop the worker's reference to it. *>
fn void fail_command(Command* command, fault failure)
{
	(void)command.op.fail(failure);
	command.op.release();
}

<*
 Fail every request still queued when the worker stops, so no caller waits
 forever. Call it from the backend's run function after its loop has ended.
*>
fn void cancel_pending(Host{Command}* host)
{
	Command[16] buffer;
	usz count = host.mailbox().take_all(buffer[..]);
	while (count > 0)
	{
		for (usz i = 0; i < count; i++)
		{
			if (buffer[i].op) fail_command(&buffer[i], error::CANCELLED);
		}
		count = host.mailbox().take_all(buffer[..]);
	}
}

<* A copy of `values`, and of every string in it, allocated from `allocator`. *>
fn String[] copy_strings(Allocator allocator, String[] values)
{
	if (values.len == 0) return { };
	String[] out = alloc::new_array(allocator, String, values.len);
	foreach (i, value : values) out[i] = value.copy(allocator);
	return out;
}

<* Finish a request successfully. Does nothing for a command without a request. *>
fn void settle_ok(Command* command)
{
	if (command.op) succeed_command(command);
}

<* Finish a request with `failure`. Does nothing for a command without a request. *>
fn void settle_fault(Command* command, fault failure)
{
	if (command.op) fail_command(command, failure);
}

<* Free strings made by `copy_strings`. *>
fn void free_strings(Allocator allocator, String[] values)
{
	if (values.len == 0) return;
	foreach (value : values) alloc::free(allocator, value.ptr);
	alloc::free(allocator, values.ptr);
}