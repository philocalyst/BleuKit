<*
 The `battery` entry of the registry: its open adapter, its commands and its `Spec`.
*>
module bleu::registry::svc_battery;
import bleu::battery, bleu::registry, bleu::registry::live, bleu::json, bleu::registry::tap;

<* Open the battery service. Its root option points at a fake sysfs tree in tests. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	battery::Options opened   = { .root = options.root };
	battery::Battery* service = battery::open(allocator, opened)!;
	return (void*)service;
}

<* `battery.refresh`: read the hardware now, instead of at the next poll. *>
fn void? refresh(registry::Request* request)
{
	battery::Battery* service = (battery::Battery*)request.handle;
	service.refresh()!;
	return registry::write_ok(request.out);
}

const registry::Command[1] COMMANDS = {
	{ .name = "battery.refresh", .summary = "Read the hardware now, instead of at the next poll.", .run = &refresh },
};

const registry::Spec BATTERY = {
	.name = "battery",
	.summary = "Battery and power sources (sysfs, UPower, IOKit, Windows)",
	.open = &open,
	.close = &live::close{battery::Battery, battery::State, battery::Cap},
	.state = &live::state{battery::Battery, battery::State, battery::Cap},
	.state_after = &live::state_after{battery::Battery, battery::State, battery::Cap},
	.capabilities = &live::capabilities{battery::Battery, battery::State, battery::Cap},
	.backend = &live::backend{battery::Battery, battery::State, battery::Cap},
	.watch = &tap::watch{battery::Battery, battery::State},
	.commands = COMMANDS[..],
};