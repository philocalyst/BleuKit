<*
 The Windows backend: RegisterHotKey on the hidden window of the worker thread.

 Sources (read 2026-10-20, see docs/research/hotkey_impl.md):
 * RegisterHotKey, UnregisterHotKey, MOD_* and MOD_NOREPEAT:
   learn.microsoft.com/windows/win32/api/winuser/nf-winuser-registerhotkey (read), winuser.h
   (MinGW-w64 mirror: MOD_NOREPEAT 0x4000, WM_HOTKEY).
 * WM_HOTKEY: learn.microsoft.com/windows/win32/inputdev/wm-hotkey, sent to the window passed to
   RegisterHotKey, or to the thread queue when the window is NULL.
 * ERROR_HOTKEY_ALREADY_REGISTERED 1409 and ERROR_HOTKEY_NOT_REGISTERED 1419: winerror.h (MinGW-w64
   mirror, read).

 A hot key is registered for the worker's window. WM_HOTKEY is not one of the messages
 `message_loop` reports, so the worker drains the queue itself: WM_HOTKEY becomes a PRESSED event,
 everything else is dispatched as `message_loop::dispatch_pending` would. Release is not reported:
 RegisterHotKey has no key-up message.
*>
module bleu::hotkey::windows @feat(WIN32) @link("user32");
import std::os::win32, std::time::clock, std::collections::maybe, std::collections::list, bleu::availability, bleu::error, bleu::hotkey, bleu::hotkey::keys, bleu::hotkey::keymap_windows, bleu::observe, bleu::rt::poller, bleu::rt::worker, bleu::win::message_loop;

const uint WM_HOTKEY = 0x0312;
const uint MOD_NOREPEAT = 0x4000;
const uint ERROR_HOTKEY_ALREADY_REGISTERED = 1409;
const uint ERROR_HOTKEY_NOT_REGISTERED = 1419;

extern fn Win32_BOOL registerHotKey(Win32_HWND window, int id, uint modifiers, uint key) @cname("RegisterHotKey");
extern fn Win32_BOOL unregisterHotKey(Win32_HWND window, int id) @cname("UnregisterHotKey");
extern fn Win32_LRESULT dispatchMessageW(win32::Win32_MSG* message) @cname("DispatchMessageW");

const Driver DRIVER = {
	.info = { "win32", "RegisterHotKey on a hidden window of the service thread", 10 },
	.id = WIN32,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// One registration of this backend. `native` is the id given to RegisterHotKey, 0 when the system does not hold it.
struct Entry
{
	String id;
	String description;
	Chord chord;
	BindingState state;
	int native;
}

struct Backend
{
	Allocator allocator;
	HotkeyHub* hub;
	void* window;
	int next_native;
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

// Ignored: `message_loop` reports power, device and display changes, which the hot keys do not need.
fn void ignore_event(void* context, message_loop::Event* event) @local
{
}

fn void run(void* state, HotkeyHub* hub, Host{Command}* host)
{
	Backend* b = (Backend*)state;
	b.hub = hub;
	message_loop::Loop* loop = message_loop::open(mem, &ignore_event, null)!!;
	defer loop.close();
	b.window = loop.window;
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
		drain_messages(b);
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++) accept(b, commands[i]);
		publish(b);
	}
	foreach (entry : b.entries)
	{
		if (entry.native != 0) unregisterHotKey(b.window, entry.native);
	}
	// Requests that arrived after the last take are refused, so no caller waits for ever.
	while (true)
	{
		usz rest = host.mailbox().take_all(commands[..]);
		if (rest == 0) break;
		for (usz i = 0; i < rest; i++) refuse(commands[i].operation, error::DISCONNECTED, "The shortcut service is closing");
	}
}

const Duration TICK = (Duration)500_000; // 0.5 s in microseconds

// Take every message queued for this thread: WM_HOTKEY is a press; the rest is dispatched.
fn void drain_messages(Backend* b) @local
{
	win32::Win32_MSG message;
	while (win32::peekMessageW(&message, null, 0, 0, win32::PM_REMOVE) != 0)
	{
		if (message.message == WM_HOTKEY)
		{
			press(b, (int)message.wParam, message.time);
			continue;
		}
		win32::translateMessage(&message);
		dispatchMessageW(&message);
	}
}

// Emit the press of the registration `native`, with the time the system stamped the message.
fn void press(Backend* b, int native, uint time) @local
{
	foreach (entry : b.entries)
	{
		if (entry.native != native) continue;
		Snapshot{Event}* packet = b.hub.emit_begin();
		Allocator arena = packet.allocator();
		packet.value = {
			.kind = PRESSED,
			.id = dup(entry.id, arena),
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
		.id = dup(command.id, b.allocator),
		.description = dup(command.description, b.allocator),
		.chord = command.chord,
		.state = BOUND,
		.native = b.next_native++,
	};
	uint modifiers = windows_modifiers(command.chord.mods) | MOD_NOREPEAT;
	if (registerHotKey(b.window, entry.native, modifiers, windows_virtual_key(command.chord.key)) == 0)
	{
		uint code = win32::getLastError();
		if (code != ERROR_HOTKEY_ALREADY_REGISTERED)
		{
			free_entry(b.allocator, &entry);
			fail_native(command.operation, error::BACKEND_FAILURE, code);
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
	if (entry.native != 0 && unregisterHotKey(b.window, entry.native) == 0)
	{
		uint code = win32::getLastError();
		if (code != ERROR_HOTKEY_NOT_REGISTERED)
		{
			fail_native(command.operation, error::BACKEND_FAILURE, code);
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
	Binding[] copies          = {};
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

// Fail `op` with the Windows error `code` as the native detail.
fn void fail_native(Task* op, fault failure, uint code) @local
{
	(void)op.fail(error::raise(failure, error::Domain.WIN32, (int)code, "RegisterHotKey or UnregisterHotKey failed"));
	op.release();
}

fn Binding copy_binding(Entry entry, Allocator allocator) @local
{
	return { .id = dup(entry.id, allocator), .description = dup(entry.description, allocator), .chord = entry.chord, .state = entry.state, .trigger = "" };
}

fn void free_entry(Allocator allocator, Entry* entry) @local
{
	drop(entry.id, allocator);
	drop(entry.description, allocator);
}
