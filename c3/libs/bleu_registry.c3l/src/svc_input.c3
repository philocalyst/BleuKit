<* The `input` entry of the registry: open adapter, commands and `Spec`. *>
module bleu::registry::svc_input;
import bleu::input, bleu::registry, bleu::registry::live, bleu::json, bleu::operation, bleu::registry::tap;

<* Open the keyboard layout service with its default backend. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	input::Input* service = input::open(allocator)!;
	return (void*)service;
}

<* `input.switch {layout}`: switch to a keyboard layout by its id. *>
fn void? switch_layout(registry::Request* request)
{
	input::Input* service             = (input::Input*)request.handle;
	input::SwitchOperation* operation = service.switch_to(request.params.string("layout")!)!;
	defer operation.release();
	input::SwitchOutcome outcome = registry::await{input::SwitchOutcome}(operation, request.timeout)!;
	return registry::write_value(request.out, "outcome", outcome);
}

<* `input.next`: switch to the next keyboard layout. *>
fn void? next(registry::Request* request)
{
	input::Input* service             = (input::Input*)request.handle;
	input::SwitchOperation* operation = service.next()!;
	defer operation.release();
	input::SwitchOutcome outcome = registry::await{input::SwitchOutcome}(operation, request.timeout)!;
	return registry::write_value(request.out, "outcome", outcome);
}

const registry::Command[2] COMMANDS = {
	{ .name = "input.switch", .summary = "Switch layout: {layout}.", .run = &switch_layout },
	{ .name = "input.next", .summary = "Switch to the next layout.", .run = &next },
};

const registry::Spec INPUT = {
	.name = "input",
	.summary = "Keyboard layouts and the current layout (compositor, locale1, TIS, Win32)",
	.open = &open,
	.close = &live::close{input::Input, input::State, input::Cap},
	.state = &live::state{input::Input, input::State, input::Cap},
	.state_after = &live::state_after{input::Input, input::State, input::Cap},
	.capabilities = &live::capabilities{input::Input, input::State, input::Cap},
	.backend = &live::backend{input::Input, input::State, input::Cap},
	.watch = &tap::watch{input::Input, input::State},
	.commands = COMMANDS[..],
};