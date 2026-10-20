<*
 The Windows backend: the clipboard API of user32.

 Change detection is polling `GetClipboardSequenceNumber`, which increments whenever the
 contents change (Microsoft, GetClipboardSequenceNumber, read 2026-10-20). The listener
 route, `AddClipboardFormatListener` with `WM_CLIPBOARDUPDATE`, is not used: `bleu::win::message_loop`
 does not route that message, and that library is read-only here. Until it does, the change
 arrives up to POLL_INTERVAL late.

 Formats: CF_UNICODETEXT is shown as `text/plain;charset=utf-8` and read as UTF-16 converted to
 UTF-8; CF_HDROP and the other standard formats are shown by name; registered formats by their
 registered name. The privacy markers are the registered names of the exclusion formats
 (`ExcludeClipboardContentFromMonitorProcessing`, and `CanIncludeInClipboardHistory` when its
 DWORD is 0). Only text is written in v1, and only text is fetched live.

 Compiled only: nothing in this file has been run.
*>
module bleu::clipboard::windows_clipboard @feat(WIN32);
import bleu::clipboard, bleu::availability, bleu::error, bleu::operation, bleu::rt::poller, bleu::rt::wakeup, bleu::rt::worker, bleu::service, bleu::win::errors, bleu::win::text, bleu::clipboard::windows_native, std::core::mem, std::os::win32, std::thread, std::time;

<* How often the sequence number is read: 250 ms, since change notifications are not used. *>
const Duration POLL_INTERVAL = (Duration)250_000;

<* The worker's state. Only the worker touches it. *>
struct WinBackend
{
	Allocator allocator;
	Board board;
	usz payload_limit;
	uint sequence;
}

const Driver DRIVER = {
	.info = { "win32", "Clipboard API (user32, Windows)", 10 },
	.id = Backend.WIN32,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	WinBackend* backend = alloc::new(allocator, WinBackend);
	backend.allocator = allocator;
	backend.payload_limit = options.payload_limit;
	backend.board.init(allocator, options.history_items, options.history_bytes, options.payload_limit);
	capabilities.init(availability::YES);
	capabilities.set(
		Cap.PRIMARY_SELECTION,
		availability::no(availability::Reason.UNSUPPORTED_OS, "Windows has no primary selection")
	);
	capabilities.set(
		Cap.WRITE_TYPES,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "v1 writes text (CF_UNICODETEXT) only")
	);
	capabilities.set(
		Cap.FETCH_TYPE,
		availability::no(availability::Reason.DEGRADED, "live fetch reads text (CF_UNICODETEXT) only in v1")
	);
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	WinBackend* backend = (WinBackend*)state;
	backend.board.free();
	alloc::free(allocator, backend);
}

<* The worker: poll the sequence number, serve commands, publish what changed. *>
fn void run(void* state, ClipboardHub* hub, Host{Command}* host)
{
	defer clipboard::fail_pending(host, error::UNAVAILABLE);
	WinBackend* backend = (WinBackend*)state;
	clipboard::publish_board(hub, &backend.board);
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	Command[8] commands;
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

<*
 Read the clipboard if its sequence number moved. A clipboard that another application holds
 is left alone until the next poll.
*>
fn void poll_changes(WinBackend* backend, ClipboardHub* hub) @private
{
	uint sequence = windows_native::getClipboardSequenceNumber();
	if (sequence == backend.sequence) return;
	if (!windows_native::open_clipboard()) return;
	backend.sequence = sequence;
	@pool()
	{
		String[] types = read_format_names(tmem);
		ulong seq      = backend.board.replace(Slot.CLIPBOARD, types, false);
		if (backend.board.text_to_read(Slot.CLIPBOARD).has_value)
		{
			if (try value = read_unicode_text(tmem, backend.payload_limit))
			{
				backend.board.captured(Slot.CLIPBOARD, seq, clipboard::MIME_UTF8_TEXT, (char[])value);
			}
		}
	};
	win32::closeClipboard();
	clipboard::emit_event(hub, EventKind.SELECTION_CHANGED, Slot.CLIPBOARD);
	clipboard::publish_board(hub, &backend.board);
}

<*
 The names of every format on the open clipboard, in `allocator`. An exclusion marker's name
 is kept only when it means exclusion; a CanIncludeInClipboardHistory that asks for inclusion is
 returned as "", which the board drops as an invalid name.
*>
fn String[] read_format_names(Allocator allocator) @private
{
	usz count = 0;
	for (uint id = windows_native::enumClipboardFormats(
		0
	); id != 0; id = windows_native::enumClipboardFormats(id)) count++;
	if (count == 0) return { };
	String[] names = alloc::alloc_array(allocator, String, (sz)count);
	usz filled     = 0;
	for (uint id = windows_native::enumClipboardFormats(
		0
	); id != 0 && filled < count; id = windows_native::enumClipboardFormats(id))
	{
		names[filled++] = format_name(allocator, id);
	}
	return names[0:filled];
}

// The name of format `id` as the board shows it.
fn String format_name(Allocator allocator, uint id) @private
{
	if (id == windows_native::CF_UNICODETEXT) return clipboard::MIME_UTF8_TEXT.copy(allocator);
	if (id == windows_native::CF_HDROP) return "CF_HDROP".copy(allocator);
	Char16[windows_native::FORMAT_NAME_CAPACITY] buffer;
	int units = windows_native::getClipboardFormatNameW(id, (WString)&buffer[0], windows_native::FORMAT_NAME_CAPACITY);
	if (units <= 0) return tformat_standard(allocator, id);
	String name = text::from_wide_units(allocator, buffer[0:units]) ?? "";
	if (name == clipboard::MARKER_WINDOWS_NO_HISTORY && dword_value(id) != 0) return "";
	return name;
}

// `win32-format/<id>` for a standard format this backend does not name.
fn String tformat_standard(Allocator allocator, uint id) @private
{
	return string::format(allocator, "win32-format/%d", id);
}

// The DWORD held by format `id` on the open clipboard; 0 when it cannot be read.
fn uint dword_value(uint id) @private
{
	Win32_HANDLE handle = win32::getClipboardData(id);
	if (!handle) return 0;
	Win32_LPVOID locked = win32::globalLock(handle);
	if (!locked) return 0;
	defer win32::globalUnlock(handle);
	return *(uint*)locked;
}

<*
 The text of CF_UNICODETEXT on the open clipboard, as UTF-8 in `allocator`. Clipboard memory
 is not always terminated, so the read stops at the first zero unit within the block.

 @return? error::OUT_OF_RANGE : "The text is larger than the payload limit"
 @return? NOT_FOUND : "The clipboard holds no CF_UNICODETEXT"
*>
fn String? read_unicode_text(Allocator allocator, usz limit) @private
{
	Win32_HANDLE handle = win32::getClipboardData(windows_native::CF_UNICODETEXT);
	if (!handle) return NOT_FOUND~;
	usz bytes = (usz)windows_native::globalSize(handle);
	if (bytes > limit) return error::OUT_OF_RANGE~;
	Char16* locked = (Char16*)win32::globalLock(handle);
	if (!locked) return error::raise(
		error::BACKEND_FAILURE,
		error::Domain.WIN32,
		0,
		"GlobalLock failed on the clipboard text"
	)~;
	defer win32::globalUnlock(handle);
	Char16[] units = locked[0:bytes / 2];
	return text::from_wide_units(allocator, units[0:clipboard::utf16_length(units)]);
}

<*
 Put `text` on the open clipboard as CF_UNICODETEXT. On success the system owns the memory.

 @return? error::BACKEND_FAILURE : "A global allocation or the SetClipboardData call failed"
*>
fn void? write_unicode_text(String text) @private
{
	@pool()
	{
		WideZ wide           = text::to_wide(tmem, text)!;
		usz bytes            = ((usz)wide.len() + 1) * 2;
		Win32_HGLOBAL memory = win32::globalAlloc(windows_native::GMEM_MOVEABLE, bytes);
		if (!memory) return errors::raise_last("GlobalAlloc")~;
		Win32_LPVOID locked = win32::globalLock(memory);
		if (!locked)
		{
			win32::globalFree(memory);
			return errors::raise_last("GlobalLock")~;
		}
		mem::copy(locked, (void*)wide.as_wstring(), (sz)bytes);
		win32::globalUnlock(memory);
		if (!win32::setClipboardData(windows_native::CF_UNICODETEXT, memory))
		{
			win32::globalFree(memory);
			return errors::raise_last("SetClipboardData")~;
		}
	};
}

// Execute one command, completing its operation.
fn void execute(WinBackend* backend, ClipboardHub* hub, Command* command) @private
{
	switch (command.kind)
	{
		case CommandKind.SET: run_set(backend, hub, command);
		case CommandKind.CLEAR: run_clear(backend, hub, command);
		case CommandKind.FETCH: run_fetch(backend, command);
		case CommandKind.DELETE: run_delete(backend, command);
	}
}

<* Own the clipboard with one text representation. Anything else is refused (v1 writes text only). *>
fn void run_set(WinBackend* backend, ClipboardHub* hub, Command* command) @private
{
	Operation{ulong}* op = (Operation{ulong}*)command.operation;
	defer op.release();
	if (command.slot == Slot.PRIMARY)
	{
		op.fail(error::UNSUPPORTED);
		return;
	}
	Representation? text_rep = text_representation(command.representations);
	if (catch err = text_rep)
	{
		op.fail(err);
		return;
	}
	if (!windows_native::open_clipboard())
	{
		op.fail(error::BUSY);
		return;
	}
	win32::emptyClipboard();
	if (catch err = write_unicode_text((String)text_rep.bytes))
	{
		win32::closeClipboard();
		op.fail(err);
		return;
	}
	win32::closeClipboard();
	ulong seq = 0;
	@pool()
	{
		String[] mimes = alloc::alloc_array(tmem, String, command.representations.len);
		foreach (i, representation : command.representations) mimes[i] = representation.mime;
		seq = backend.board.replace(Slot.CLIPBOARD, mimes, true);
		backend.board.captured(Slot.CLIPBOARD, seq, text_rep.mime, text_rep.bytes);
	};
	backend.sequence = windows_native::getClipboardSequenceNumber();
	clipboard::emit_event(hub, EventKind.SELECTION_CHANGED, Slot.CLIPBOARD);
	clipboard::publish_board(hub, &backend.board);
	op.succeed(seq);
}

// The one representation that is text. An unsupported type makes the whole set fail.
fn Representation? text_representation(Representation[] representations) @private
{
	Representation? found = NOT_FOUND~;
	foreach (representation : representations)
	{
		if (!clipboard::choose_text_type({ representation.mime }).has_value) return error::UNSUPPORTED~;
		found = representation;
	}
	return found;
}

fn void run_clear(WinBackend* backend, ClipboardHub* hub, Command* command) @private
{
	Operation{bool}* op = (Operation{bool}*)command.operation;
	defer op.release();
	if (command.slot == Slot.PRIMARY)
	{
		op.fail(error::UNSUPPORTED);
		return;
	}
	if (!windows_native::open_clipboard())
	{
		op.fail(error::BUSY);
		return;
	}
	bool held = backend.board.lane(Slot.CLIPBOARD).present;
	win32::emptyClipboard();
	win32::closeClipboard();
	backend.board.clear(Slot.CLIPBOARD);
	backend.sequence = windows_native::getClipboardSequenceNumber();
	clipboard::emit_event(hub, EventKind.SELECTION_CHANGED, Slot.CLIPBOARD);
	clipboard::publish_board(hub, &backend.board);
	op.succeed(held);
}

// From the history when the entry holds the type, otherwise the text of the live clipboard while it is the current copy.
fn void run_fetch(WinBackend* backend, Command* command) @private
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
	if (!lane.present || lane.seq != command.id || !clipboard::choose_text_type({ command.mime }).has_value)
	{
		op.fail(error::UNAVAILABLE);
		return;
	}
	if (!windows_native::open_clipboard())
	{
		op.fail(error::BUSY);
		return;
	}
	defer win32::closeClipboard();
	if (try value = read_unicode_text(op.allocator(), backend.payload_limit))
	{
		op.succeed((char[])value);
		return;
	}
	op.fail(error::UNAVAILABLE);
}

fn void run_delete(WinBackend* backend, Command* command) @private
{
	Operation{bool}* op = (Operation{bool}*)command.operation;
	defer op.release();
	op.succeed(backend.board.delete(command.id));
}