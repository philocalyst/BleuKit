<* The `power` entry of the registry: open adapter, commands and `Spec`. *>
module bleu::registry::svc_power;
import bleu::power, bleu::registry, bleu::registry::live, bleu::json, bleu::registry::tap;

<* Open the power service with its default backend. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	power::Power* service = power::open(allocator)!;
	return (void*)service;
}

<* `power.set_profile {profile}`: switch to a power profile, waiting for the platform to confirm. *>
fn void? set_profile(registry::Request* request)
{
	power::Power* service = (power::Power*)request.handle;
	power::Profile profile = registry::parse_enum{power::Profile}(request.params.string("profile")!)!;
	power::ProfileOperation* operation = service.set_profile(profile)!;
	defer operation.release();
	power::Profile applied = registry::await{power::Profile}(operation, request.timeout)!;
	return registry::write_value(request.out, "profile", applied);
}

<* `power.perform {action}`: suspend, hibernate, reboot ... as the platform allows. *>
fn void? perform(registry::Request* request)
{
	power::Power* service = (power::Power*)request.handle;
	power::Action action = registry::parse_enum{power::Action}(request.params.string("action")!)!;
	power::ActionOperation* operation = service.perform(action)!;
	defer operation.release();
	power::Action done = registry::await{power::Action}(operation, request.timeout)!;
	return registry::write_value(request.out, "action", done);
}

const registry::Command[2] COMMANDS = {
	{ .name = "power.set_profile", .summary = "Switch the power profile: {profile}.", .run = &set_profile },
	{ .name = "power.perform", .summary = "Suspend, hibernate, reboot ...: {action}.", .run = &perform },
};

const registry::Spec POWER = {
	.name = "power",
	.summary = "Power profile, sleep, shutdown and idle hints (logind, macOS, Windows)",
	.open = &open,
	.close = &live::close{power::Power, power::State, power::Cap},
	.state = &live::state{power::Power, power::State, power::Cap},
	.state_after = &live::state_after{power::Power, power::State, power::Cap},
	.capabilities = &live::capabilities{power::Power, power::State, power::Cap},
	.backend = &live::backend{power::Power, power::State, power::Cap},
	.watch = &tap::watch{power::Power, power::State},
	.commands = COMMANDS[..],
};
