<*
 The Windows backend: `GetSystemPowerStatus` plus the battery class IOCTLs.

 The worker owns a hidden message window (`bleu::win::message_loop`) for the duration of
 the run. Its power-setting and device-change notifications only enqueue a REFRESH on
 the worker's mailbox; the worker reads the hardware itself. A poll behind the mailbox
 covers a missed notification or a failed registration.

 Each refresh reads the summary, then every battery device. If no device answers and the
 summary reports a battery, the summary is published as one source with the id "system".
 The sources are the first half of the design; the detail is in `windows_ioctl.c3`.
*>
module bleu::battery::win32 @feat(WIN32);
import std::collections::list, std::time, bleu::availability, bleu::battery, bleu::observe, bleu::rt::mailbox, bleu::rt::poller, bleu::rt::worker, bleu::service, bleu::win::message_loop;

struct Backend
{
	Duration poll;
	Startup* startup;
	Notifier notifier;
}

<*
 What the window callback needs: the mailbox to enqueue into. The callback runs on the
 worker's own thread (the window belongs to it), and still only enqueues, as the other
 backends do for their foreign callbacks.
*>
struct Notifier
{
	Mailbox{Command}* mailbox;
}

const Driver DRIVER = {
	.info = { "win32", "GetSystemPowerStatus with the battery class IOCTLs", 10 },
	.id = WIN32,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

<* GetSystemPowerStatus succeeds on every Windows system, so the probe asks it. *>
fn bool probe(Options* options)
{
	SystemPowerStatus status;
	return get_system_power_status(&status) != 0;
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities, Startup* startup)
{
	capabilities.init(availability::YES);
	capabilities.set(
		Cap.TEMPERATURE,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"BatteryTemperature's unit is single-source (deci-Kelvin, starship-battery); not read in v1"
		)
	);
	capabilities.set(
		Cap.IDENTITY,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"Device name, manufacturer and serial are IOCTL string levels; not read in v1"
		)
	);
	capabilities.set(
		Cap.PERIPHERALS,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"Peripheral batteries are not researched for Windows"
		)
	);
	capabilities.set(
		Cap.HEALTH,
		battery::degraded(
			"Design and full capacity come from the battery class IOCTLs; without them only the summary is published"
		)
	);
	capabilities.set(
		Cap.CYCLES,
		battery::degraded("Cycle count comes from the battery class IOCTLs; without them it is unknown")
	);
	capabilities.set(
		Cap.POWER,
		battery::degraded("Flow comes from the battery class IOCTLs (Rate); the summary has no rate")
	);
	capabilities.set(
		Cap.TIME_ESTIMATE,
		battery::degraded("Computed from capacity and rate; the summary uses BatteryLifeTime")
	);
	Backend* backend = alloc::new(allocator, Backend, { .poll = options.poll, .startup = startup });
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

<*
 The window callback. Power-setting, power-state and device-change messages request a
 refresh; everything else is ignored. Only enqueues.
*>
fn void on_message(void* context, message_loop::Event* event) @local
{
	Notifier* notifier = (Notifier*)context;
	bool relevant      = event.kind == message_loop::EventKind.POWER_SETTING
		|| event.kind == message_loop::EventKind.POWER_STATE
		|| event.kind == message_loop::EventKind.DEVICE_CHANGE;
	if (!relevant) return;
	if (catch notifier.mailbox.post(Command.REFRESH))
	{
		// Full (a refresh is already queued) or closed (the service is stopping).
	}
}

<*
 The registrations of one run. Each is optional: a failed one leaves the poll to cover
 its changes. Closed by `run`.
*>
struct Watches
{
	message_loop::PowerWatch mains;
	message_loop::PowerWatch percent;
	message_loop::DeviceWatch batteries;
}

<* Register for mains, battery percentage and battery device arrival on `loop`. *>
fn void watch_changes(message_loop::Loop* loop, Watches* watches)
{
	if (try w = loop.watch_power(message_loop::GUID_ACDC_POWER_SOURCE)) watches.mains = w;
	if (try w = loop.watch_power(message_loop::GUID_BATTERY_PERCENTAGE_REMAINING)) watches.percent = w;
	if (try w = loop.watch_devices(BATTERY_CLASS)) watches.batteries = w;
}

<* Release the registrations that were made. *>
fn void close_watches(message_loop::Loop* loop, Watches* watches)
{
	if (watches.mains.handle != null)
	{
		if (catch watches.mains.close())
		{
		}
	}
	if (watches.percent.handle != null)
	{
		if (catch watches.percent.close())
		{
		}
	}
	if (watches.batteries.handle != null)
	{
		if (catch watches.batteries.close())
		{
		}
	}
	loop.close();
}

<* Read the hardware once and publish the result. A failed read keeps the last good state, marked stale. *>
fn void refresh(BatteryHub* hub)
{
	Snapshot{State}* snapshot = hub.begin();
	State? state              = read_all(snapshot.allocator());
	if (catch err = state)
	{
		battery::publish_failure(hub, snapshot);
		return;
	}
	snapshot.value = state;
	battery::publish_reading(hub, snapshot);
}

<*
 Build the state: the summary's mains line, then every battery device, falling back to
 the summary as one source when no device answered.
*>
fn State? read_all(Allocator allocator)
{
	@pool()
	{
		SystemPowerStatus summary = read_summary()!;
		bool on_mains             = summary_on_mains((uint)summary.ac_line_status);
		List{battery::Source} sources;
		sources.init(tmem);
		usz skipped = 0;
		if (try set = battery_devices())
		{
			defer set.close();
			uint index = 0;
			while (true)
			{
				String? path = set.path(index);
				if (catch err = path)
				{
					// The end of the list ends the loop; a device that cannot be named is counted as skipped.
					if (err == NO_MORE_ELEMENT) break;
					skipped++;
					index++;
					continue;
				}
				if (try source = read_device(allocator, path))
				{
					sources.push(source);
				}
				else
				{
					skipped++;
				}
				index++;
			}
		}
		else
		{
			// SetupAPI could not list the batteries: the summary below stands in, and the reading says so.
			skipped++;
		}
		if (sources.array_view().len == 0 && summary_has_battery((uint)summary.battery_flag))
		{
			sources.push(summary_source(allocator, &summary, on_mains));
		}
		State state = { .on_mains = on_mains };
		state.reading = battery::reading_after(skipped);
		if (sources.array_view().len > 0)
		{
			state.sources = alloc::clone_slice(allocator, sources.array_view());
		}
		return state;
	};
}

fn void run(void* state, BatteryHub* hub, Host{Command}* host)
{
	Backend* backend = (Backend*)state;
	Poller poller;
	if (catch err = poller.init(mem, host.wakeup(), 0, true))
	{
		backend.startup.fail(err);
		return;
	}
	defer poller.free();
	backend.startup.succeed();
	backend.notifier.mailbox = host.mailbox();
	Watches watches;
	message_loop::Loop* loop = null;
	if (try opened = message_loop::open(mem, &on_message, &backend.notifier))
	{
		loop = opened;
		watch_changes(loop, &watches);
	}
	Command[8] commands;
	refresh(hub);
	while (!host.stopping())
	{
		// Sleeps until the poll interval passes, a window message arrives, or a refresh is queued.
		if (catch poller.wait(backend.poll))
		{
			// TIMEOUT is the normal poll tick.
		}
		message_loop::dispatch_pending();
		usz count = host.mailbox().take_all(commands[..]);
		(void)count;
		refresh(hub);
	}
	if (loop != null) close_watches(loop, &watches);
}