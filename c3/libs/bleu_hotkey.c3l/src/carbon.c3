<*
 The macOS backend: Carbon's RegisterEventHotKey, bound at run time through bleu::dl.

 Sources (read 2026-10-20):
 * RegisterEventHotKey, UnregisterEventHotKey, kEventHotKeyExclusive (1), kEventHotKeyPressed (5),
   kEventHotKeyReleased (6), kEventClassKeyboard ('keyb'), typeEventHotKeyID ('hkid'), the
   event-handler installation: Carbon HIToolbox CarbonEvents.h (MacOSX10.13 SDK, phracker mirror).
 * cmdKey, shiftKey, optionKey, controlKey bits 8, 9, 11, 12: HIToolbox Events.h (same SDK).
 * The call sequence (GetApplicationEventTarget, InstallEventHandler, RegisterEventHotKey with the
   8-byte EventHotKeyID, GetEventParameter with kEventParamDirectObject = '----' = 757935405):
   global-hotkey 0.7.0 src/platform_impl/macos/mod.rs and ffi.rs (crate read; the constant is its
   bindgen output). Hammerspoon extensions/hotkey/libhotkey.m (raw file read) uses the same
   parameter and the dispatcher target instead.

 Not verified on a Mac: that a worker thread may call the Carbon registration functions (Hammerspoon
 calls them on the main thread), and that presses are delivered while the host's main thread runs its
 event loop. The callback only enqueues the press and signals the worker; it never publishes.
 RegisterEventHotKey returns an OSStatus on a clash; its code (eventHotKeyExistsErr) is not in the
 headers read here, so a clash is reported as BACKEND_FAILURE, not CONFLICT.
*>
module bleu::hotkey::carbon @feat(DARWIN);
import std::thread, std::time::clock, std::collections::maybe, std::collections::list, bleu::availability, bleu::dl, bleu::dl::lazy, bleu::error, bleu::hotkey, bleu::hotkey::keys, bleu::hotkey::keymap_macos, bleu::observe, bleu::rt::poller, bleu::rt::wakeup, bleu::rt::worker;

const String[1] CARBON_LIBRARIES = { "/System/Library/Frameworks/Carbon.framework/Carbon" };

const uint CLASS_KEYBOARD = 0x6B657962;     // 'keyb' (kEventClassKeyboard)
const uint EVENT_HOT_KEY_PRESSED = 5;       // kEventHotKeyPressed
const uint EVENT_HOT_KEY_RELEASED = 6;      // kEventHotKeyReleased
const uint PARAM_DIRECT_OBJECT = 0x2D2D2D2D; // '----' (kEventParamDirectObject)
const uint TYPE_HOT_KEY_ID = 0x686B6964;    // 'hkid' (typeEventHotKeyID)
const uint HOT_KEY_EXCLUSIVE = 1;           // kEventHotKeyExclusive
const uint SIGNATURE = 0x626C6575;          // 'bleu': the owner of our hot keys
const int NO_ERROR = 0;                     // noErr
const int EXCLUSIVE_NONE = 0;
const usz QUEUE_CAPACITY = 64;
const Duration TICK = (Duration)500_000;    // 0.5 s in microseconds

// Carbon's EventHotKeyID, passed by value to RegisterEventHotKey and filled by GetEventParameter.
struct EventHotKeyID
{
	uint signature;
	uint id;
}

// Carbon's EventTypeSpec.
struct EventTypeSpec
{
	uint event_class;
	uint event_kind;
}

alias RegisterFn = fn int(uint code, uint modifiers, ulong hotkey_id, void* target, uint options, void** reference);
alias UnregisterFn = fn int(void* reference);
alias TargetFn = fn void*();
alias InstallFn = fn int(void* target, void* handler, uint count, EventTypeSpec* types, void* user, void** reference);
alias RemoveFn = fn int(void* reference);
alias KindFn = fn uint(void* event);
alias ParameterFn = fn int(void* event, uint name, uint type, void* actual_type, uint size, void* actual_size, void* data);

<* The Carbon functions this backend uses, bound once per process. A missing one leaves the table unbound. *>
struct CarbonApi
{
	TargetFn application_target @tag("sym", "GetApplicationEventTarget");
	RegisterFn register_hotkey @tag("sym", "RegisterEventHotKey");
	UnregisterFn unregister_hotkey @tag("sym", "UnregisterEventHotKey");
	InstallFn install_handler @tag("sym", "InstallEventHandler");
	RemoveFn remove_handler @tag("sym", "RemoveEventHandler");
	KindFn event_kind @tag("sym", "GetEventKind");
	ParameterFn event_parameter @tag("sym", "GetEventParameter");
}

lazy::Lazy{CarbonApi} carbon_table;

fn CarbonApi*? carbon_api()
{
	return carbon_table.get(CARBON_LIBRARIES[..]);
}

const Driver DRIVER = {
	.info = { "carbon", "Carbon RegisterEventHotKey on the application event target", 10 },
	.id = CARBON,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// One press or release, queued by the Carbon callback for the worker.
struct Press
{
	int native;
	bool pressed;
}

// Presses from the callback thread. The callback only appends here and signals the worker.
struct Queue
{
	Mutex mutex;
	Press[QUEUE_CAPACITY] items;
	usz count;
	usz dropped;
}

// One registration. `reference` is the EventHotKeyRef, null when the system does not hold it.
struct Entry
{
	String id;
	String description;
	Chord chord;
	int native;
	void* reference;
}

struct Backend
{
	Allocator allocator;
	HotkeyHub* hub;
	CarbonApi* api;
	Wakeup* wakeup;
	Queue queue;
	int next_native;
	bool installed;
	Availability registration;
	List{Entry} entries;
}

// Whether the Carbon functions bind here.
fn bool probe(Options* options)
{
	if (try api = carbon_api()) return api != null;
	return false;
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.set(
		Cap.REGISTER,
		availability::no(
			availability::Reason.DEGRADED,
			"Presses arrive on the main thread's event loop, which the host must run (not verified on a Mac)"
		)
	);
	capabilities.set(
		Cap.CONFLICT_REPORT,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"A clash makes RegisterEventHotKey fail; that failure is not classified as CONFLICT here"
		)
	);
	capabilities.set(
		Cap.ACTIVATION_TOKEN,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "Carbon hot-key events carry no activation token")
	);
	capabilities.set(
		Cap.PLATFORM_TIMESTAMP,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "The event time of a hot-key event is not read")
	);
	Backend* backend = alloc::new(allocator, Backend);
	backend.allocator = allocator;
	backend.next_native = 1;
	backend.registration = availability::no(availability::Reason.BACKEND_STOPPED, "The Carbon handler is not installed");
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
	b.wakeup = host.wakeup();
	if (catch err = carbon_api()) return;
	b.api = carbon_api()!!;
	b.queue.mutex.init()!!;
	defer b.queue.mutex.destroy();
	EventTypeSpec[2] types = { { CLASS_KEYBOARD, EVENT_HOT_KEY_PRESSED }, { CLASS_KEYBOARD, EVENT_HOT_KEY_RELEASED } };
	void* handler = null;
	if (b.api.install_handler(b.api.application_target(), (void*)&on_hot_key, 2, &types, b, &handler) == NO_ERROR)
	{
		b.installed = true;
		b.registration = availability::YES;
	}
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	publish(b);
	Command[8] commands;
	while (!host.stopping())
	{
		// Sleeps until a press is queued, a request arrives, or the tick passes.
		if (catch poller.wait(TICK))
		{
			// TIMEOUT is the normal tick.
		}
		deliver_presses(b);
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++) accept(b, commands[i]);
		publish(b);
	}
	foreach (entry : b.entries)
	{
		if (entry.reference != null) b.api.unregister_hotkey(entry.reference);
	}
	if (b.installed) b.api.remove_handler(handler);
	// Requests that arrived after the last take are refused, so no caller waits for ever.
	while (true)
	{
		usz rest = host.mailbox().take_all(commands[..]);
		if (rest == 0) break;
		for (usz i = 0; i < rest; i++) refuse(commands[i].operation, error::DISCONNECTED, "The shortcut service is closing");
	}
}

// The Carbon event handler. Runs on the thread that runs the event loop: it only queues the press.
fn int on_hot_key(void* next_handler, void* event, void* user)
{
	Backend* b = (Backend*)user;
	EventHotKeyID id;
	int status = b.api.event_parameter(event, PARAM_DIRECT_OBJECT, TYPE_HOT_KEY_ID, null, (uint)@sizeof(id), null, &id);
	if (status != NO_ERROR) return status;
	bool pressed = b.api.event_kind(event) == EVENT_HOT_KEY_PRESSED;
	queue_press(b, (int)id.id, pressed);
	return NO_ERROR;
}

fn void queue_press(Backend* b, int native, bool pressed) @local
{
	b.queue.mutex.lock()!!;
	if (b.queue.count < QUEUE_CAPACITY)
	{
		b.queue.items[b.queue.count++] = { .native = native, .pressed = pressed };
	}
	else
	{
		b.queue.dropped++;
	}
	b.queue.mutex.unlock();
	b.wakeup.signal()!!;
}

// Emit the queued presses and releases, on the worker thread.
fn void deliver_presses(Backend* b) @local
{
	b.queue.mutex.lock()!!;
	Press[QUEUE_CAPACITY] pending;
	usz count = b.queue.count;
	for (usz i = 0; i < count; i++) pending[i] = b.queue.items[i];
	b.queue.count = 0;
	b.queue.mutex.unlock();
	for (usz i = 0; i < count; i++) emit_press(b, pending[i]);
}

fn void emit_press(Backend* b, Press press) @local
{
	foreach (entry : b.entries)
	{
		if (entry.native != press.native) continue;
		Snapshot{Event}* packet = b.hub.emit_begin();
		Allocator arena = packet.allocator();
		packet.value = {
			.kind = press.pressed ? PRESSED : RELEASED,
			.id = hotkey::text_copy(entry.id, arena),
			.at = clock::now(),
			.platform_time = maybe::value(0UL),
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
	if (!b.registration.ok())
	{
		refuse(command.operation, b.registration.refusal(), b.registration.note);
		return;
	}
	if (find(b, command.id) >= 0)
	{
		refuse(command.operation, error::INVALID_STATE, "A shortcut with this id is already registered");
		return;
	}
	if (try code = keymap_macos::macos_keycode(command.chord.key))
	{
		register_code(b, command, code);
		return;
	}
	refuse(command.operation, error::UNSUPPORTED, "macOS has no key code for this key");
}

fn void register_code(Backend* b, Command command, uint code) @local
{
	int native = b.next_native++;
	ulong hotkey_id = (ulong)SIGNATURE | ((ulong)native << 32); // EventHotKeyID, by value, little-endian
	void* reference = null;
	uint modifiers = keymap_macos::macos_modifiers(command.chord.mods);
	int status = b.api.register_hotkey(code, modifiers, hotkey_id, b.api.application_target(), HOT_KEY_EXCLUSIVE, &reference);
	if (status != NO_ERROR)
	{
		fail_status(command.operation, status);
		return;
	}
	Entry entry = {
		.id = hotkey::text_copy(command.id, b.allocator),
		.description = hotkey::text_copy(command.description, b.allocator),
		.chord = command.chord,
		.native = native,
		.reference = reference,
	};
	b.entries.push(entry);
	(void)command.operation.succeed(binding_of(entry, command.operation.allocator()));
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
	Entry removed = b.entries.get(index);
	b.entries.remove_at(index);
	if (removed.reference != null)
	{
		int status = b.api.unregister_hotkey(removed.reference);
		if (status != NO_ERROR)
		{
			fail_status(command.operation, status);
			return;
		}
	}
	(void)command.operation.succeed(binding_of(removed, command.operation.allocator()));
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
		for (sz i = 0; i < b.entries.len(); i++) copies[i] = binding_of(b.entries.get(i), arena);
	}
	snapshot.value = { .bindings = copies, .portal_version = 0, .registration = b.registration };
	b.hub.publish_if_changed(snapshot);
}

// A registration as the caller sees it: BOUND, since RegisterEventHotKey has no other answer.
fn Binding binding_of(Entry entry, Allocator allocator) @local
{
	return { .id = hotkey::text_copy(entry.id, allocator), .description = hotkey::text_copy(entry.description, allocator), .chord = entry.chord, .state = BOUND, .trigger = "" };
}

fn void free_entry(Allocator allocator, Entry* entry) @local
{
	hotkey::text_free(entry.id, allocator);
	hotkey::text_free(entry.description, allocator);
}

fn void refuse(Task* op, fault failure, String text) @local
{
	(void)op.fail(error::raise(failure, error::Domain.INTERNAL, 0, "%s", text));
	op.release();
}

// Fail `op` with the OSStatus as the native detail.
fn void fail_status(Task* op, int status) @local
{
	(void)op.fail(error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, status, "RegisterEventHotKey or UnregisterEventHotKey returned OSStatus %d", status));
	op.release();
}
