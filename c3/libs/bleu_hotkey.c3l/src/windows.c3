<*
 The Windows backend: RegisterHotKey on the hidden window of the worker thread.

 Sources (read 2026-10-20, see docs/research/hotkey_impl.md):
 * RegisterHotKey, UnregisterHotKey, MOD_* and MOD_NOREPEAT:
 learn.microsoft.com/windows/win32/api/winuser/nf-winuser-registerhotkey (read), winuser.h
 (MinGW-w64 mirror: MOD_NOREPEAT 0x4000, WM_HOTKEY).
 * WM_HOTKEY: learn.microsoft.com/windows/win32/inputdev/wm-hotkey, sent to the window passed to
 RegisterHotKey, or to the thread queue when the window is NULL.
 * ERROR_HOTKEY_ALREADY_REGISTERED 1409 and ERROR_HOTKEY_NOT_REGISTERED 1419: winerror.h (MinGW-w64
 mirror, read); mapped by `bleu::win::hresult` to BUSY and NOT_FOUND.

 A hot key is registered through `bleu::win::message_loop.Loop`, which owns the hidden window and
 reports WM_HOTKEY as a HOTKEY event on this worker. Release is not reported: RegisterHotKey has no
 key-up message. A chord another program holds fails with BUSY; the registration is then kept as a
 CONFLICT binding that cannot fire.
*>
module bleu::hotkey::windows @feat(WIN32) @link("user32");
import std::time::clock, std::collections::maybe, std::collections::list, bleu::availability, bleu::error, bleu::hotkey, bleu::hotkey::keys, bleu::hotkey::keymap_windows, bleu::observe, bleu::rt::poller, bleu::rt::worker, bleu::win::message_loop;

const Driver DRIVER = {
	.info = { "win32", "RegisterHotKey on a hidden window of the service thread", 10 },
	.id = WIN32,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// One registration of this backend. `native` is the id given to the loop's `register_hotkey`, 0 when the system does not hold it.
struct Entry
{
	String id;
	String description;
	Chord chord;
	BindingState state;
	uint native;
}

struct Backend
{
	Allocator allocator;
	HotkeyHub* hub;
	// The hidden window and its hot keys. Opened by `run` on the worker thread, closed when `run` returns.
	message_loop::Loop* loop;
	uint next_native;
	List{Entry} entries;
}

// RegisterHotKey has been in every Windows version this library targets: the probe is only a check.
fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.set(
		Cap.PRESS_RELEASE,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"RegisterHotKey reports the press (WM_HOTKEY) only; there is no key-up message"
		)
	);
	capabilities.set(
		Cap.ACTIVATION_TOKEN,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "No activation token comes with WM_HOTKEY")
	);
	Backend* backend = alloc::new(allocator, Backend);
	backend.allocator = allocator;
	backend.next_native = 1;
	backend.entries.init(allocator);
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	Backend* b = (Backend*)state;
	foreach (entry : b.entries) free_entry(b.allocator, &entry);
	b.entries.free();
	alloc::free(allocator, b);
}

fn void run(void* state, HotkeyHub* hub, Host{Command}* host)
{
	Backend* b = (Backend*)state;
	b.hub = hub;
	message_loop::Loop* loop = message_loop::open(mem, &on_event, b) ?? null;
	if (loop == null) return;
	defer loop.close();
	b.loop = loop;
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1, true)) return;
	defer poller.free();
	publish(b);
	Command[8] commands;
	while (!host.stopping())
	{
		// Sleeps until a message or a request arrives, or the tick passes.
		if (catch poller.wait(TICK))
		{
			// TIMEOUT is the normal tick.
		}
		// WM_HOTKEY reaches `on_event` here, as a press.
		message_loop::dispatch_pending();
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++) accept(b, commands[i]);
		publish(b);
	}
	// Requests that arrived after the last take are refused, so no caller waits for ever.
	while (true)
	{
		usz rest = host.mailbox().take_all(commands[..]);
		if (rest == 0) break;
		for (usz i = 0; i < rest; i++) refuse(
			commands[i].operation,
			error::DISCONNECTED,
			"The shortcut service is closing"
		);
	}
}

const Duration TICK = (Duration)500_000; // 0.5 s in microseconds

<* Hot-key presses arrive here on the worker thread. The loop's other events are not this backend's. *>
fn void on_event(void* context, message_loop::Event* event) @local
{
	if (event.kind != message_loop::EventKind.HOTKEY) return;
	press((Backend*)context, event.hotkey_id, event.time);
}

// Emit the press of the registration `native`, with the time the system stamped the message.
fn void press(Backend* b, uint native, uint time) @local
{
	foreach (entry : b.entries)
	{
		if (entry.native != native) continue;
		Snapshot{hotkey::Event}* packet = b.hub.emit_begin();
		Allocator arena                 = packet.allocator();
		packet.value = {
			.kind = PRESSED,
			.id = hotkey::text_copy(entry.id, arena),
			.at = clock::now(),
			.platform_time = maybe::value((ulong)time),
			.activation_token = "",
		};
		b.hub.emit(packet);
		return;
	}
}

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
	if (find(b, command.id) >= 0)
	{
		refuse(command.operation, error::INVALID_STATE, "A shortcut with this id is already registered");
		return;
	}
	Entry entry = {
		.id = hotkey::text_copy(command.id, b.allocator),
		.description = hotkey::text_copy(command.description, b.allocator),
		.chord = command.chord,
		.state = BOUND,
		.native = b.next_native++,
	};
	uint modifiers = keymap_windows::windows_modifiers(command.chord.mods) | message_loop::MOD_NOREPEAT;
	uint key       = keymap_windows::windows_virtual_key(command.chord.key);
	if (catch failure = b.loop.register_hotkey(entry.native, modifiers, key))
	{
		if (failure != error::BUSY)
		{
			free_entry(b.allocator, &entry);
			(void)command.operation.fail(failure);
			command.operation.release();
			return;
		}
		// Another program holds the chord: the registration exists, but it cannot fire.
		entry.state = CONFLICT;
		entry.native = 0;
	}
	b.entries.push(entry);
	(void)command.operation.succeed(copy_binding(entry, command.operation.allocator()));
	command.operation.release();
}

fn void accept_unregister(Backend* b, Command command)
{
	sz index = find(b, command.id);
	if (index < 0)
	{
		refuse(command.operation, NOT_FOUND, "No shortcut has this id");
		return;
	}
	Entry* entry = b.entries.get_ref(index);
	if (entry.native != 0)
	{
		if (catch failure = b.loop.unregister_hotkey(entry.native))
		{
			(void)command.operation.fail(failure);
			command.operation.release();
			return;
		}
	}
	Entry removed = b.entries.get(index);
	b.entries.remove_at(index);
	(void)command.operation.succeed(copy_binding(removed, command.operation.allocator()));
	free_entry(b.allocator, &removed);
	command.operation.release();
}

// The index of the registration `id`, or -1.
fn sz find(Backend* b, String id) @local
{
	for (sz i = 0; i < b.entries.len(); i++)
	{
		if (b.entries.get(i).id == id) return i;
	}
	return -1;
}

// Publish the registrations as they stand, if they changed.
fn void publish(Backend* b) @local
{
	Snapshot{State}* snapshot = b.hub.begin();
	Allocator arena           = snapshot.allocator();
	Binding[] copies          = { };
	if (b.entries.len() > 0)
	{
		copies = alloc::new_array(arena, Binding, b.entries.len());
		for (sz i = 0; i < b.entries.len(); i++) copies[i] = copy_binding(b.entries.get(i), arena);
	}
	snapshot.value = { .bindings = copies, .portal_version = 0, .registration = availability::YES };
	b.hub.publish_if_changed(snapshot);
}

fn void refuse(Task* op, fault failure, String text) @local
{
	(void)op.fail(error::raise(failure, error::Domain.INTERNAL, 0, "%s", text));
	op.release();
}

fn Binding copy_binding(Entry entry, Allocator allocator) @local
{
	return {
		.id = hotkey::text_copy(entry.id, allocator),
		.description = hotkey::text_copy(entry.description, allocator),
		.chord = entry.chord,
		.state = entry.state,
		.trigger = ""
	};
}

fn void free_entry(Allocator allocator, Entry* entry) @local
{
	hotkey::text_free(entry.id, allocator);
	hotkey::text_free(entry.description, allocator);
}