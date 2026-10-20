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
	State previous_sources;
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

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	// What the kernel interface cannot tell us at all, on any hardware.
	return alloc::new(allocator, Backend, { .root = options.root.copy(allocator), .poll = options.poll });
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
		// An unreadable tree is an empty one: the subsystem went away.
		snapshot.value = { };
	}
	else
	{
		snapshot.value = state;
	}
	hub.publish_if_changed(snapshot);
}

fn void run(void* state, BatteryHub* hub, Host{Command}* host)
{
	Backend* backend = (Backend*)state;
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 0)) return;
	defer poller.free();
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