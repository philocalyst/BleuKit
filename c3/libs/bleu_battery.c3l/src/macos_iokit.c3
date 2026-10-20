<*
 The IOKit backend: IOPowerSources and the IORegistry `IOPMPowerSource` record.

 Power-source changes arrive on a run loop of our own (`bleu::cf::runloop`), which
 runs `IOPSNotificationCreateRunLoopSource` and does nothing else: its callback
 enqueues a REFRESH on the worker's mailbox. The worker reads the hardware on its
 own thread, as ARCHITECTURE.md requires for foreign callbacks. A slow poll behind
 the mailbox covers a missed notification.

 Sources: IOPowerSources as declared in Apple's IOKit headers (through
 `bleu::iokit::power`, cited there); the registry keys in `iokit_read.c3`.
*>
module bleu::battery::iokit @feat(DARWIN);
import std::thread, std::time, bleu::availability, bleu::battery, bleu::cf, bleu::cf::runloop, bleu::iokit::power, bleu::observe, bleu::rt::mailbox, bleu::rt::poller, bleu::rt::worker;

struct Backend
{
	Duration poll;
	Startup* startup;
	Notifier notifier;
	RunLoopThread loop;
	// Set when the run loop thread could not be joined: it may still call the callback, which reads
	// the notifier, so the backend is deliberately not freed.
	bool orphaned;
}

<*
 What the power-source callback needs: the mailbox to enqueue into, and the
 IOPS source it is attached through (owned, closed by `run`). The mutex guards
 `mailbox` and `closed`: once `closed` is set the callback enqueues nothing, so the
 mailbox may be freed while the run loop thread is still alive.
*>
struct Notifier
{
	Mutex mutex;
	bool closed;
	Mailbox{Command}* mailbox;
	cf::Ref source;
}

const Driver DRIVER = {
	.info = { "iokit", "macOS IOPowerSources with the IORegistry IOPMPowerSource record", 10 },
	.id = IOKIT,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

<* IOPowerSources answers on every Mac, desktops included, so the probe reads it once. *>
fn bool probe(Options* options)
{
	@pool()
	{
		if (catch err = power::read_power_sources(tmem)) return false;
		return true;
	};
}

<* Whether the machine registers an `IOPMPowerSource` record (a battery is installed). *>
fn bool has_battery_record() @local
{
	if (try record = battery_record())
	{
		record.close();
		return true;
	}
	return false;
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities, Startup* startup)
{
	capabilities.init(availability::YES);
	bool registry = has_battery_record();
	Availability no_registry = availability::no(
		availability::Reason.HARDWARE_ABSENT,
		"This Mac has no IOPMPowerSource record: no internal battery"
	);
	capabilities.set(Cap.HEALTH, registry ? availability::YES : no_registry);
	capabilities.set(Cap.CYCLES, registry ? availability::YES : no_registry);
	capabilities.set(Cap.IDENTITY, registry ? availability::YES : no_registry);
	capabilities.set(
		Cap.POWER,
		registry ? availability::no(
			availability::Reason.DEGRADED,
			"Magnitude from Amperage x Voltage; the direction follows the charge state"
		)
			: no_registry
	);
	capabilities.set(
		Cap.TEMPERATURE,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"The unit of the registry Temperature key is unresolved (docs/research/battery_impl.md)"
		)
	);
	capabilities.set(
		Cap.PERIPHERALS,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "Peripheral batteries are not read on macOS in v1")
	);
	Backend* backend = alloc::new(allocator, Backend, { .poll = options.poll, .startup = startup });
	backend.notifier.mutex.init()!!;
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	Backend* backend = (Backend*)state;
	if (backend.orphaned) return;
	backend.notifier.mutex.destroy();
	alloc::free(allocator, state);
}

<*
 Runs on the run-loop thread before the loop runs: create the IOPS source and attach it.
 A failure leaves `notifier.source` empty and the poll alone refreshes the state.
*>
fn void attach_notifications(void* loop, void* context) @local
{
	Notifier* notifier = (Notifier*)context;
	if (try source = power::power_source_change_source(&on_power_source_changed, notifier))
	{
		notifier.source = source;
		power::attach_source(loop, source.ptr);
	}
}

<*
 Runs on the run-loop thread for every change. Only enqueues. A full or closed mailbox
 needs no second refresh: a refresh is already queued, or the service is stopping.
*>
fn void on_power_source_changed(void* context) @local
{
	Notifier* notifier = (Notifier*)context;
	notifier.mutex.lock()!!;
	defer notifier.mutex.unlock();
	if (notifier.closed) return;
	if (catch notifier.mailbox.post(REFRESH))
	{
		// Full (a refresh is already queued) or closed (the service is stopping).
	}
}

<* Read the hardware once and publish the result if it differs from the last. *>
fn void refresh(BatteryHub* hub)
{
	Snapshot{State}* snapshot = hub.begin();
	State? state              = read_all(snapshot.allocator());
	if (catch err = state)
	{
		// IOPowerSources failed: republish the last good reading as stale, never an empty state (publish.c3).
		battery::publish_failure(hub, snapshot);
		return;
	}
	snapshot.value = state;
	battery::publish_reading(hub, snapshot);
}

fn void run(void* state, BatteryHub* hub, Host{Command}* host)
{
	Backend* backend = (Backend*)state;
	Poller poller;
	if (catch err = poller.init(mem, host.wakeup(), 0))
	{
		backend.startup.fail(err);
		return;
	}
	defer poller.free();
	backend.startup.succeed();
	backend.notifier.mutex.lock()!!;
	backend.notifier.mailbox = host.mailbox();
	backend.notifier.mutex.unlock()!!;
	bool notifying = true;
	if (catch backend.loop.start(&attach_notifications, &backend.notifier, null, null))
	{
		// No run loop: the poll below is the only refresh. The state stays correct, just later.
		notifying = false;
	}
	Command[8] commands;
	refresh(hub);
	while (!host.stopping())
	{
		// Sleeps until the poll interval passes or a refresh is queued from the run loop.
		if (catch poller.wait(backend.poll))
		{
			// TIMEOUT is the normal poll tick.
		}
		usz count = host.mailbox().take_all(commands[..]);
		(void)count;
		refresh(hub);
	}
	// Closing first stops the callback from touching the mailbox, which the hub frees once this returns.
	backend.notifier.mutex.lock()!!;
	backend.notifier.closed = true;
	backend.notifier.mutex.unlock()!!;
	if (notifying)
	{
		if (catch backend.loop.stop_and_join())
		{
			// The loop thread may still run the callback, which reads the notifier: keep the backend alive.
			backend.orphaned = true;
		}
	}
	backend.notifier.source.close();
}