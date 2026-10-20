<*
 The sampling loop every backend shares: sample, publish, serve commands, wait.

 A backend supplies one `SampleFn` that reads the whole machine into a snapshot.
 The loop owns the clock: it measures the real time between samples and passes
 it on, so rates and percentages are right even when a tick runs late. Commands
 are served while waiting, so a kill does not wait for the next sample.
*>
module bleu::sysinfo;
import std::time::clock, bleu::equal, bleu::error, bleu::observe, bleu::rt::poller, bleu::rt::worker, bleu::service, bleu::deadline;

<*
 Fills `snapshot.value` completely (strings and arrays from `snapshot.allocator()`).
 `elapsed` is the real time since the previous sample. A failing sample is
 dropped: the last published state stays the newest.
*>
alias SampleFn = fn void?(void* reader, Snapshot{State}* snapshot, Duration elapsed);

<* A backend's reader and its sample function. *>
struct Sampler
{
	void* reader;
	SampleFn sample;
}

<* Most commands that one wait serves. *>
const usz COMMAND_BATCH = 8;

<*
 Run until the host stops. `interval` is the nominal period between samples;
 the wait ends at the period's deadline, or earlier to serve commands.

 @param interval : "Nominal period between samples, at least MINIMUM_INTERVAL"
*>
fn void run_sampler(Sampler* sampler, SysinfoHub* hub, WorkerHost* host, Duration interval)
{
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 0)) return;
	defer poller.free();
	Command[COMMAND_BATCH] commands;
	Clock previous_start = clock::now();
	while (!host.stopping())
	{
		Clock started = clock::now();
		Duration elapsed = (started - previous_start).to_duration();
		previous_start = started;
		publish_sample(sampler, hub, elapsed);
		Deadline next = deadline::after(interval);
		while (!host.stopping() && !next.expired())
		{
			if (catch err = poller.wait(next.remaining()))
			{
				// TIMEOUT is the normal end of the wait; anything else means the poller is broken.
				if (err != TIMEOUT) return;
			}
			usz count = host.mailbox().take_all(commands[..]);
			for (usz i = 0; i < count; i++)
			{
				run_command(&commands[i]);
			}
		}
	}
}

<*
 Take one sample and publish it, unless it equals the newest state. Transients
 (a volume or an interface appearing or disappearing) are emitted after the
 state that shows them, so a reader that re-reads the state sees the change.
*>
fn void publish_sample(Sampler* sampler, SysinfoHub* hub, Duration elapsed)
{
	Snapshot{State}* snapshot = hub.begin();
	if (catch err = sampler.sample(sampler.reader, snapshot, elapsed))
	{
		snapshot.release();
		return;
	}
	StateSnapshot*? earlier = hub.latest();
	if (try before = earlier)
	{
		bool unchanged = equal::deep(before.value, snapshot.value);
		if (unchanged)
		{
			before.release();
			snapshot.release();
			return;
		}
	}
	StateSnapshot* kept = snapshot.retain();
	(void)hub.publish(snapshot);
	if (try before = earlier)
	{
		emit_topology(hub, &before.value, &kept.value);
		before.release();
	}
	kept.release();
}

<* Emit an event for each mount point and interface name that appeared or disappeared. *>
fn void emit_topology(SysinfoHub* hub, State* before, State* after)
{
	@pool()
	{
		String[] old_mounts = mount_points(before.mounts);
		String[] new_mounts = mount_points(after.mounts);
		emit_differences(hub, old_mounts, new_mounts, MOUNT_ADDED, MOUNT_REMOVED);
		String[] old_names = interface_names(before.interfaces);
		String[] new_names = interface_names(after.interfaces);
		emit_differences(hub, old_names, new_names, INTERFACE_ADDED, INTERFACE_REMOVED);
	};
}

fn String[] mount_points(Mount[] mounts) @local
{
	String[] names = alloc::new_array(tmem, String, mounts.len);
	foreach (i, &mount : mounts) names[i] = mount.mount_point;
	return names;
}

fn String[] interface_names(NetInterface[] interfaces) @local
{
	String[] names = alloc::new_array(tmem, String, interfaces.len);
	foreach (i, &interface : interfaces) names[i] = interface.name;
	return names;
}

fn void emit_differences(SysinfoHub* hub, String[] before, String[] after, EventKind added, EventKind removed) @local
{
	foreach (name : after)
	{
		if (!contains(before, name)) emit(hub, added, name);
	}
	foreach (name : before)
	{
		if (!contains(after, name)) emit(hub, removed, name);
	}
}

fn bool contains(String[] names, String name) @local
{
	foreach (candidate : names)
	{
		if (candidate == name) return true;
	}
	return false;
}

fn void emit(SysinfoHub* hub, EventKind kind, String name) @local
{
	Packet{Event}* packet = hub.emit_begin();
	packet.value = { .kind = kind, .name = name.copy(packet.allocator()) };
	hub.emit(packet);
}
