<* The `brightness` entry of the registry: open adapter, commands and `Spec`. *>
module bleu::registry::svc_brightness;
import bleu::brightness, bleu::registry, bleu::registry::live, bleu::json, bleu::unit, bleu::registry::tap;

<* Open the brightness service. Its root points at a fake sysfs tree in tests. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	brightness::Options opened = { .root = options.root };
	brightness::Brightness* service = brightness::open(allocator, opened)!;
	return (void*)service;
}

<*
 `brightness.set {device, level, policy?, mechanism?}`: set a display's brightness.
 `policy` is prefer_hardware (the default), allow_software or exact; `mechanism`
 is read only for `exact`, and names one of the backlight mechanisms.
*>
fn void? set(registry::Request* request)
{
	brightness::Brightness* service = (brightness::Brightness*)request.handle;
	String device = request.params.string("device")!;
	Level level = (Level)(float)request.params.number("level")!;
	brightness::Policy policy = brightness::DEFAULT_POLICY;
	String kind = registry::string_or(request.params, "policy", "prefer_hardware")!;
	policy.kind = registry::parse_enum{brightness::PolicyKind}(kind)!;
	if (policy.kind == brightness::PolicyKind.EXACT)
	{
		String mechanism = registry::string_or(request.params, "mechanism", "backlight")!;
		policy.mechanism = registry::parse_enum{brightness::Mechanism}(mechanism)!;
	}
	brightness::SetOperation* operation = service.set_level(device, level, policy)!;
	defer operation.release();
	brightness::Applied applied = registry::await{brightness::Applied}(operation, request.timeout)!;
	return registry::write_value(request.out, "applied", applied);
}

const registry::Command[2] COMMANDS = {
	{ .name = "brightness.set", .summary = "Set brightness: {device, level, policy?, mechanism?}.", .run = &set },
	{ .name = "brightness.refresh", .summary = "Read the devices now.", .run = &refresh },
};

<* `brightness.refresh`: re-read the devices now. *>
fn void? refresh(registry::Request* request)
{
	brightness::Brightness* service = (brightness::Brightness*)request.handle;
	service.refresh()!;
	return registry::write_ok(request.out);
}

const registry::Spec BRIGHTNESS = {
	.name = "brightness",
	.summary = "Display and keyboard brightness (sysfs, DDC/CI, DisplayServices, IOCTL)",
	.open = &open,
	.close = &live::close{brightness::Brightness, brightness::State, brightness::Cap},
	.state = &live::state{brightness::Brightness, brightness::State, brightness::Cap},
	.state_after = &live::state_after{brightness::Brightness, brightness::State, brightness::Cap},
	.capabilities = &live::capabilities{brightness::Brightness, brightness::State, brightness::Cap},
	.backend = &live::backend{brightness::Brightness, brightness::State, brightness::Cap},
	.watch = &tap::watch{brightness::Brightness, brightness::State},
	.commands = COMMANDS[..],
};
