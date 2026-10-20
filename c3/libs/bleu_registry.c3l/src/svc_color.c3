<* The `color` entry of the registry: open adapter, commands and `Spec`. *>
module bleu::registry::svc_color;
import bleu::color, bleu::registry, bleu::registry::live, bleu::json, bleu::unit;

<* Open the colour service with its default backend. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	color::Color* service = color::open(allocator)!;
	return (void*)service;
}

<* `color.set_temperature {output?, kelvin}`: set the colour temperature of one output, or of all. *>
fn void? set_temperature(registry::Request* request)
{
	color::Color* service = (color::Color*)request.handle;
	String output = registry::string_or(request.params, "output", color::ALL_OUTPUTS);
	Kelvin kelvin = (Kelvin)request.params.integer("kelvin")!;
	color::ApplyOperation* operation = service.set_temperature(output, kelvin)!;
	defer operation.release();
	color::Applied applied = registry::await(operation, request.timeout)!;
	return registry::write_value(request.out, "applied", applied);
}

<* `color.set_dim {output?, level}`: set the software dimming of one output, or of all. *>
fn void? set_dim(registry::Request* request)
{
	color::Color* service = (color::Color*)request.handle;
	String output = registry::string_or(request.params, "output", color::ALL_OUTPUTS);
	Level level = (Level)(float)request.params.number("level")!;
	color::ApplyOperation* operation = service.set_dim(output, level)!;
	defer operation.release();
	color::Applied applied = registry::await(operation, request.timeout)!;
	return registry::write_value(request.out, "applied", applied);
}

<* `color.reset`: remove the temperature and dimming that the service applied. *>
fn void? reset(registry::Request* request)
{
	color::Color* service = (color::Color*)request.handle;
	color::ApplyOperation* operation = service.reset()!;
	defer operation.release();
	color::Applied applied = registry::await(operation, request.timeout)!;
	return registry::write_value(request.out, "applied", applied);
}

const registry::Command[3] COMMANDS = {
	{ .name = "color.set_temperature", .summary = "Set the colour temperature: {output?, kelvin}.", .run = &set_temperature },
	{ .name = "color.set_dim", .summary = "Set software dimming: {output?, level}.", .run = &set_dim },
	{ .name = "color.reset", .summary = "Remove the temperature and dimming.", .run = &reset },
};

const registry::Spec COLOR = {
	.name = "color",
	.summary = "Night light and gamma ramps (wlr-gamma-control, Windows ramps, CoreGraphics)",
	.open = &open,
	.close = &live::close{color::Color, color::State, color::Cap},
	.state = &live::state{color::Color, color::State, color::Cap},
	.state_after = &live::state_after{color::Color, color::State, color::Cap},
	.capabilities = &live::capabilities{color::Color, color::State, color::Cap},
	.backend = &live::backend{color::Color, color::State, color::Cap},
	.watch = &live::watch{color::Color, color::State, color::Cap},
	.commands = COMMANDS[..],
};
