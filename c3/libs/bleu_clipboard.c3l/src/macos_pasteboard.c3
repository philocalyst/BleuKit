<*
 The macOS backend: NSPasteboard, the general pasteboard.

 Change detection is polling: NSPasteboard has no notification for a change, but
 `changeCount` increments whenever the pasteboard's ownership changes
 (developer.apple.com NSPasteboard.changeCount, read 2026-10-20). The worker reads it every
 POLL_INTERVAL and reads the content only when it moved. Our own writes update the stored
 count right away, so they are not read back as foreign copies.

 Types are pasteboard type identifiers. The UTI `public.utf8-plain-text` is shown as the MIME
 name `text/plain;charset=utf-8` so that the text logic is the same on every platform; every
 other identifier is shown as it is (the `org.nspasteboard.*` markers are identifiers already).

 Not done: the macOS 15.4 pasteboard privacy control (`accessBehavior`) is not used; its names are
 UNVERIFIED (docs/research/session_windows_input.md). The primary selection does not exist here.

 Compiled only: nothing in this file has been run.
*>
module bleu::clipboard::macos_pasteboard @feat(DARWIN);
import std::os::darwin::objc, std::collections::maybe, std::time, bleu::clipboard, bleu::availability, bleu::error, bleu::objc, bleu::objc::foundation, bleu::objc::notify, bleu::operation, bleu::rt::poller, bleu::rt::worker, bleu::service;

// Linking: NSPasteboard lives in AppKit. `bleu::objc::notify` carries the `AppKit.framework` link.

<* The pasteboard identifier for UTF-8 text (NSPasteboardTypeString's documented value, public.utf8-plain-text). *>
const String UTI_TEXT        = "public.utf8-plain-text";
<* How often the change count is read: 500 ms, as the research note's poll interval for polling backends. *>
const Duration POLL_INTERVAL = (Duration)500_000;

<* The worker's state. Only the worker touches it. *>
struct PasteboardBackend
{
	Allocator allocator;
	Board board;
	long change_count;
	usz payload_limit;
}

const Driver DRIVER = {
	.info = { "pasteboard", "NSPasteboard, the general pasteboard (macOS)", 10 },
	.id = Backend.PASTEBOARD,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// NSPasteboard is part of AppKit, present on every macOS.
fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	PasteboardBackend* backend = alloc::new(allocator, PasteboardBackend);
	backend.allocator = allocator;
	backend.payload_limit = options.payload_limit;
	backend.board.init(allocator, options.history_items, options.history_bytes, options.payload_limit);
	capabilities.init(availability::YES);
	capabilities.set(
		Cap.PRIMARY_SELECTION,
		availability::no(availability::Reason.UNSUPPORTED_OS, "macOS has no primary selection")
	);
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	PasteboardBackend* backend = (PasteboardBackend*)state;
	backend.board.free();
	alloc::free(allocator, backend);
}

<* The worker: poll the change count, serve commands, publish what changed. *>
fn void run(void* state, ClipboardHub* hub, Host{Command}* host)
{
	defer fail_pending(host, error::UNAVAILABLE);
	PasteboardBackend* backend = (PasteboardBackend*)state;
	clipboard::publish_board(hub, &backend.board);
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	Command[8] commands;
	backend.change_count = general_change_count();
	while (!host.stopping())
	{
		if (catch poller.wait(POLL_INTERVAL))
		{
		}
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++) execute(backend, hub, &commands[i]);
		poll_changes(backend, hub);
	}
	backend.board.clear(Slot.CLIPBOARD);
	clipboard::publish_board(hub, &backend.board);
}

// The general pasteboard, retained for the caller.
fn Obj general_pasteboard() @private
{
	return objc::borrow(objc::class_named("NSPasteboard").send(ObjId, "generalPasteboard"));
}

fn long general_change_count() @private
{
	Obj pasteboard = general_pasteboard();
	defer pasteboard.close();
	return pasteboard.send_long("changeCount");
}

<* Read the content if the change count moved since the last look. *>
fn void poll_changes(PasteboardBackend* backend, ClipboardHub* hub) @private
{
	long count = general_change_count();
	if (count == backend.change_count) return;
	backend.change_count = count;
	@pool()
	{
		Obj pasteboard = general_pasteboard();
		defer pasteboard.close();
		String[] types     = read_types(tmem, pasteboard);
		ulong seq          = backend.board.replace(Slot.CLIPBOARD, types, false);
		Maybe{String} text = backend.board.text_to_read(Slot.CLIPBOARD);
		if (text.has_value)
		{
			if (try value = read_string(tmem, pasteboard, UTI_TEXT))
			{
				backend.board.captured(Slot.CLIPBOARD, seq, text.value, (char[])value);
			}
		}
	};
	clipboard::emit_event(hub, EventKind.SELECTION_CHANGED, Slot.CLIPBOARD);
	clipboard::publish_board(hub, &backend.board);
}

// The types on the pasteboard, translated to the names the board uses, in a copy in `allocator`.
fn String[] read_types(Allocator allocator, Obj pasteboard) @private
{
	ObjId array    = pasteboard.send_id("types");
	usz count      = foundation::array_count(array);
	String[] types = alloc::alloc_array(allocator, String, (sz)count);
	for (usz i = 0; i < count; i++)
	{
		String name = foundation::to_string(foundation::array_at(array, i), allocator) ?? "";
		types[i] = name == UTI_TEXT ? clipboard::MIME_UTF8_TEXT : name;
	}
	return types;
}

// The string of `type` on the pasteboard, copied into `allocator`; error when there is none.
fn String? read_string(Allocator allocator, Obj pasteboard, String type) @private
{
	Obj type_name = foundation::from_string(type);
	defer type_name.close();
	ObjId value = pasteboard.send_id("stringForType:", type_name.ptr);
	if (!value) return NOT_FOUND~;
	return foundation::to_string(value, allocator);
}

// Execute one command, completing its operation.
fn void execute(PasteboardBackend* backend, ClipboardHub* hub, Command* command) @private
{
	switch (command.kind)
	{
		case CommandKind.SET: run_set(backend, hub, command);
		case CommandKind.CLEAR: run_clear(backend, hub, command);
		case CommandKind.FETCH: run_fetch(backend, command);
		case CommandKind.DELETE: run_delete(backend, command);
	}
}

<* Own the general pasteboard with the representations: text as a string, anything else as data. *>
fn void run_set(PasteboardBackend* backend, ClipboardHub* hub, Command* command) @private
{
	Operation{ulong}* op = (Operation{ulong}*)command.operation;
	defer op.release();
	if (command.slot == Slot.PRIMARY)
	{
		op.fail(error::UNSUPPORTED);
		return;
	}
	Obj pasteboard = general_pasteboard();
	defer pasteboard.close();
	pasteboard.send_long("clearContents");
	ulong seq = 0;
	@pool()
	{
		String[] mimes = alloc::alloc_array(tmem, String, command.representations.len);
		foreach (i, representation : command.representations)
		{
			mimes[i] = representation.mime;
			write_representation(pasteboard, representation);
		}
		seq = backend.board.replace(Slot.CLIPBOARD, mimes, true);
		foreach (representation : command.representations)
		{
			if (is_text_type(
				representation.mime
			)) backend.board.captured(Slot.CLIPBOARD, seq, representation.mime, representation.bytes);
		}
	};
	backend.change_count = general_change_count();
	clipboard::emit_event(hub, EventKind.SELECTION_CHANGED, Slot.CLIPBOARD);
	clipboard::publish_board(hub, &backend.board);
	op.succeed(seq);
}

// The pasteboard identifier of a MIME name: the text names map to the UTI, others stay.
fn String pasteboard_type(String mime) @private => is_text_type(mime) ? UTI_TEXT : mime;

// Whether the board reads `mime` as text.
fn bool is_text_type(String mime) @private => clipboard::choose_text_type({ mime }).has_value;

// Write one representation onto the pasteboard (already cleared).
fn void write_representation(Obj pasteboard, Representation representation) @private
{
	Obj type_name = foundation::from_string(pasteboard_type(representation.mime));
	defer type_name.close();
	if (is_text_type(representation.mime))
	{
		Obj text = foundation::from_string((String)representation.bytes);
		defer text.close();
		pasteboard.send_bool("setString:forType:", text.ptr, type_name.ptr);
		return;
	}
	Obj data = foundation::from_bytes(representation.bytes);
	defer data.close();
	pasteboard.send_bool("setData:forType:", data.ptr, type_name.ptr);
}

fn void run_clear(PasteboardBackend* backend, ClipboardHub* hub, Command* command) @private
{
	Operation{bool}* op = (Operation{bool}*)command.operation;
	defer op.release();
	if (command.slot == Slot.PRIMARY)
	{
		op.fail(error::UNSUPPORTED);
		return;
	}
	bool held      = backend.board.lane(Slot.CLIPBOARD).present;
	Obj pasteboard = general_pasteboard();
	defer pasteboard.close();
	pasteboard.send_long("clearContents");
	backend.board.clear(Slot.CLIPBOARD);
	backend.change_count = general_change_count();
	clipboard::emit_event(hub, EventKind.SELECTION_CHANGED, Slot.CLIPBOARD);
	clipboard::publish_board(hub, &backend.board);
	op.succeed(held);
}

<* From the history when the entry holds the type, otherwise from the pasteboard while it is the current copy. *>
fn void run_fetch(PasteboardBackend* backend, Command* command) @private
{
	Operation{Bytes}* op = (Operation{Bytes}*)command.operation;
	defer op.release();
	Item* item = backend.board.find(command.id);
	if (item != null && item.mime == command.mime)
	{
		op.succeed(alloc::clone_slice(op.allocator(), item.bytes));
		return;
	}
	Lane* lane = backend.board.lane(Slot.CLIPBOARD);
	if (!lane.present || lane.seq != command.id)
	{
		op.fail(error::UNAVAILABLE);
		return;
	}
	@pool()
	{
		Obj pasteboard = general_pasteboard();
		defer pasteboard.close();
		Obj type_name = foundation::from_string(pasteboard_type(command.mime));
		defer type_name.close();
		ObjId data = pasteboard.send_id("dataForType:", type_name.ptr);
		if (!data)
		{
			op.fail(NOT_FOUND);
			return;
		}
		char[]? bytes = foundation::data_bytes(data, tmem);
		if (catch err = bytes)
		{
			op.fail(err);
			return;
		}
		if ((usz)bytes.len > backend.payload_limit)
		{
			op.fail(error::OUT_OF_RANGE);
			return;
		}
		op.succeed(alloc::clone_slice(op.allocator(), bytes));
	};
}

fn void run_delete(PasteboardBackend* backend, Command* command) @private
{
	Operation{bool}* op = (Operation{bool}*)command.operation;
	defer op.release();
	op.succeed(backend.board.delete(command.id));
}