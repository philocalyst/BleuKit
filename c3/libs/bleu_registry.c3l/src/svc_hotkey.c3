<* The `hotkey` entry of the registry: open adapter, commands and `Spec`. *>
module bleu::registry::svc_hotkey;
import bleu::hotkey, bleu::registry, bleu::registry::live, bleu::json, bleu::operation, bleu::registry::tap;

<* Open the global hotkey service with its default backend. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	hotkey::Options opened  = { };
	hotkey::Hotkey* service = hotkey::open(allocator, opened)!;
	return (void*)service;
}

<*
 `hotkey.register {id, description, chord}`: bind a chord such as "Ctrl+Shift+K".
 Each press later arrives as an event of the hotkey service.
*>
fn void? register(registry::Request* request)
{
	hotkey::Hotkey* service = (hotkey::Hotkey*)request.handle;
	String id               = request.params.string("id")!;
	String description      = registry::string_or(request.params, "description", "")!;
	hotkey::Chord chord     = hotkey::parse_chord(request.params.string("chord")!)!;
	hotkey::Task* operation = service.register(id, description, chord)!;
	defer operation.release();
	hotkey::Binding binding = registry::await{hotkey::Binding}(operation, request.timeout)!;
	return registry::write_value(request.out, "binding", binding);
}

<* `hotkey.unregister {id}`: remove a binding. *>
fn void? unregister(registry::Request* request)
{
	hotkey::Hotkey* service = (hotkey::Hotkey*)request.handle;
	hotkey::Task* operation = service.unregister(request.params.string("id")!)!;
	defer operation.release();
	registry::await{hotkey::Binding}(operation, request.timeout)!;
	return registry::write_ok(request.out);
}

const registry::Command[2] COMMANDS = {
	{ .name = "hotkey.register", .summary = "Bind a chord: {id, description?, chord}.", .run = &register },
	{ .name = "hotkey.unregister", .summary = "Remove a binding: {id}.", .run = &unregister },
};

const registry::Spec HOTKEY = {
	.name = "hotkey",
	.summary = "Global shortcuts (XDG portal, Carbon, Win32 hooks)",
	.open = &open,
	.close = &live::close{hotkey::Hotkey, hotkey::State, hotkey::Cap},
	.state = &live::state{hotkey::Hotkey, hotkey::State, hotkey::Cap},
	.state_after = &live::state_after{hotkey::Hotkey, hotkey::State, hotkey::Cap},
	.capabilities = &live::capabilities{hotkey::Hotkey, hotkey::State, hotkey::Cap},
	.backend = &live::backend{hotkey::Hotkey, hotkey::State, hotkey::Cap},
	.watch = &tap::watch{hotkey::Hotkey, hotkey::State},
	.commands = COMMANDS[..],
};