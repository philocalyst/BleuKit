<*
 The sysfs backend: polls `/sys/class/power_supply`.

 Needs no daemon and no permissions, which makes it the universal Linux
 fallback behind UPower. The kernel sends uevents when batteries change, but a
 poll every few seconds is what status bars have always done and keeps this
 backend free of netlink; `REFRESH` forces an immediate read.
*>
module bleu::battery::sysfs @feat(LINUX);
import std::io::path, std::time, bleu::availability, bleu::battery, bleu::error, bleu::observe, bleu::rt::poller, bleu::rt::worker, bleu::service;

struct Backend
{
	String root;
	Duration poll;
	Startup* startup;
}

const Driver DRIVER = {
	.info = { "sysfs", "Linux kernel power_supply class (/sys/class/power_supply)", 10 },
	.id = SYSFS,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

fn bool probe(Options* options)
{
	@pool()
	{
		return path::is_dir((Path)string::tformat("%s%s", options.root, SUPPLY_DIR));
	};
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities, Startup* startup)
{
	capabilities.init(availability::YES);
	// sysfs maps a supply to MAINS, BATTERY, UPS or UNKNOWN; peripheral batteries come only from UPower.
	capabilities.set(
		PERIPHERALS,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"sysfs has no peripheral devices; see the upower backend"
		)
	);
	// What the kernel interface cannot tell us at all, on any hardware.
	return alloc::new(allocator, Backend, { .root = options.root.copy(allocator), .poll = options.poll, .startup = startup });
}

fn void destroy(Allocator allocator, void* state)
{
	Backend* backend = (Backend*)state;
	alloc::free(allocator, backend.root.ptr);
	alloc::free(allocator, backend);
}

<* Read the hardware once and publish the result if it differs from the last. *>
fn void refresh(Backend* backend, BatteryHub* hub)
{
	Snapshot{State}* snapshot = hub.begin();
	State? state              = read_all(snapshot.allocator(), backend.root);
	if (catch err = state)
	{
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
	Command[8] commands;
	refresh(backend, hub);
	while (!host.stopping())
	{
		// Sleeps until the next poll or until the mailbox is signalled.
		if (catch poller.wait(backend.poll))
		{
			// TIMEOUT is the normal poll tick.
		}
		usz count = host.mailbox().take_all(commands[..]);
		(void)count;
		refresh(backend, hub);
	}
}
