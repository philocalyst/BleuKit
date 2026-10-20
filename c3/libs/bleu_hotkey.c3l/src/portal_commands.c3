<*
 Accepting the requests the worker receives: registrations join the desired set and wait for the next
 round; removals leave it at once and wait for the round that binds the rest.
*>
module bleu::hotkey::portal @feat(LINUX);
import bleu::availability, bleu::error, bleu::hotkey, bleu::operation;

// Take one request from the mailbox.
fn void accept(Backend* b, Command command)
{
	switch (command.kind)
	{
		case CommandKind.REGISTER: accept_register(b, command);
		case CommandKind.UNREGISTER: accept_unregister(b, command);
	}
}

fn void accept_register(Backend* b, Command command)
{
	if (!b.registration.ok())
	{
		refuse_command(command, b.registration.refusal(), b.registration.note);
		return;
	}
	if (find_index(b, command.id) >= 0)
	{
		refuse_command(command, error::INVALID_STATE, "A shortcut with this id is already registered");
		return;
	}
	Binding binding = {
		.id = dup(command.id, b.allocator),
		.description = dup(command.description, b.allocator),
		.chord = command.chord,
		.state = PENDING,
	};
	b.bindings.push(binding);
	b.waiting.push({ .operation = command.operation, .id = dup(command.id, b.allocator), .removal = false });
	b.dirty = true;
}

fn void accept_unregister(Backend* b, Command command)
{
	sz index = find_index(b, command.id);
	if (index < 0)
	{
		refuse_command(command, NOT_FOUND, "No shortcut has this id");
		return;
	}
	Binding removed = b.bindings.get(index);
	b.bindings.remove_at(index);
	b.waiting.push({ .operation = command.operation, .removed = removed, .removal = true });
	b.dirty = true;
}

<* Complete a request that will not be served, with `failure`; releases its reference. *>
fn void refuse_command(Command command, fault failure, String text)
{
	fail_waiting_op(command.operation, failure, text);
	command.operation.release();
}

// The index of the registration `id`, or -1.
fn sz find_index(Backend* b, String id)
{
	for (sz i = 0; i < b.bindings.len(); i++)
	{
		if (b.bindings.get(i).id == id) return i;
	}
	return -1;
}

// A deep copy of `binding` in `allocator`.
fn Binding copy_binding(Binding binding, Allocator allocator)
{
	return {
		.id = dup(binding.id, allocator),
		.description = dup(binding.description, allocator),
		.chord = binding.chord,
		.state = binding.state,
		.trigger = dup(binding.trigger, allocator),
	};
}

// Free the strings of a binding made by `copy_binding` or `accept_register`.
fn void free_binding(Allocator allocator, Binding* binding)
{
	drop(binding.id, allocator);
	drop(binding.description, allocator);
	drop(binding.trigger, allocator);
	binding.id = "";
	binding.description = "";
	binding.trigger = "";
}
