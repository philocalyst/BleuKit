<*
 The `clipboard` module: DMS's clipboard methods and the `clipboard` topic over `bleu::clipboard`.

 Methods served: `clipboard.getState`, `getHistory`, `getEntry`, `deleteEntry`,
 `deleteEntries`, `clearHistory`, `copy`, `copyEntry`, `paste`, `pasteSupported`,
 `getConfig`, `setConfig`. Topic: `clipboard` (`State` on every change of either selection).
 Refused: the methods Bleu has no source for (pins, search, paste keystrokes, file lists,
 editing); see `replies` and the table below.

 Source of every shape and rule: `core/internal/server/clipboard/` at DMS master
 8be08999 (types.go, handlers.go). What Bleu cannot give, and what differs: docs/DMSD.md.
*>
module dmsd::clipboard_mod;
import std::collections::list, std::time, bleu::clipboard, bleu::error, bleu::ipc, bleu::json, bleu::observe, bleu::operation, dmsd::contract, dmsd::wire, dmsd::params, dmsd::param_lists, dmsd::replies;

const String[1] TOPICS       = { "clipboard" };
const String[1] CAPABILITIES = { "clipboard" };

// DMS's `DefaultConfig` (clipboard/types.go:28-35): the history keeps 100 copies, and a copy may be 5 MiB.
// The running service is opened with these, so `getConfig` reports what it enforces.
const uint HISTORY_ITEMS = 100;
const usz PAYLOAD_LIMIT  = 5 * 1024 * 1024;
// How long a read, a write or a delete of the selection may take before the reply says so.
const Duration OPERATION_TIMEOUT = (Duration)5_000_000;
// Reply when there is no state yet: the empty history, with capture on (the service is open).
const String EMPTY_STATE = "{\"enabled\":true,\"history\":[]}";
// Text types in the order `paste` prefers them.
const String[5] TEXT_TYPES = { "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT" };
// Reply text for `clipboard.subscribe`: the streaming form cannot reply in this protocol.
const String SUBSCRIBE_UNSUPPORTED = "not supported: a streaming method cannot reply in this protocol; subscribe with services [\"clipboard\"] instead";

// The refused methods. Each has no Bleu source; the reason is the reply.
const replies::Refusal[10] REFUSALS = {
	{ .method = "clipboard.subscribe", .text = SUBSCRIBE_UNSUPPORTED },
	{ .method = "clipboard.sendPaste", .text = "not supported: Bleu cannot send a paste keystroke (it has no virtual keyboard)" },
	{ .method = "clipboard.search", .text = "not supported: search over the clipboard history is not built; Bleu keeps text copies only, with no index" },
	{ .method = "clipboard.store", .text = "not supported: Bleu cannot add an entry to the history without taking the selection" },
	{ .method = "clipboard.pinEntry", .text = "not supported: Bleu's clipboard history has no pinned entries" },
	{ .method = "clipboard.unpinEntry", .text = "not supported: Bleu's clipboard history has no pinned entries" },
	{ .method = "clipboard.getPinnedEntries", .text = "not supported: Bleu's clipboard history has no pinned entries" },
	{ .method = "clipboard.getPinnedCount", .text = "not supported: Bleu's clipboard history has no pinned entries" },
	{ .method = "clipboard.editEntry", .text = "not supported: Bleu's clipboard history entries cannot be edited" },
	{ .method = "clipboard.copyFile", .text = "not supported: Bleu cannot offer a file list on the clipboard (text and raw types only)" },
};

<* The module's runtime state. Allocated in `start`, freed in `stop`. *>
struct ClipboardModule
{
	clipboard::Clipboard* service;
	contract::StatePump state_pump;
	observe::WatchId{clipboard::State} watch_id;
}

// The first MIME type of an entry, which is what DMS calls `mimeType`; "" when it has none.
fn String primary_mime(String[] types)
{
	return types.len > 0 ? types[0] : "";
}

// The first text type `types` offers, in TEXT_TYPES order; "" when it offers none.
fn String text_type(String[] types)
{
	foreach (preferred : TEXT_TYPES)
	{
		foreach (offered : types)
		{
			if (offered == preferred) return preferred;
		}
	}
	return "";
}

<*
 One DMS `Entry` (clipboard/types.go:99-111). `data` is the payload when it was read, and
 is left out when empty (`omitempty`). Bleu's copies are text only, so `isImage` is false;
 pins do not exist, so `pinned` is false; `hash`, `altData` and `altMimeType` are not kept.
*>
fn void? write_entry(json::JsonWriter* writer, clipboard::Entry* entry, char[] data)
{
	writer.begin_object()!;
	wire::key_uint(writer, "id", entry.id)!;
	if (data.len > 0) wire::key_bytes(writer, "data", data)!;
	wire::key_string(writer, "mimeType", primary_mime(entry.mime_types))!;
	wire::key_string(writer, "preview", entry.preview)!;
	wire::key_int(writer, "size", (long)entry.size)!;
	wire::key_time(writer, "timestamp", entry.time)!;
	wire::key_bool(writer, "isImage", false)!;
	wire::key_bool(writer, "pinned", false)!;
	writer.end_object()!;
}

// The history of one snapshot as a DMS `Entry` array, without payloads (as DMS's GetHistory does).
fn void? write_history(json::JsonWriter* writer, clipboard::State* state)
{
	writer.begin_array()!;
	foreach (&entry : state.history) write_entry(writer, entry, (char[])"")!;
	writer.end_array()!;
}

<*
 DMS's `clipboard.State` (clipboard/types.go:113-117). `enabled` is true while the
 service captures, which is the only state Bleu has. `history` carries no payloads.
 `current` is left out: Bleu's selection has no capture time, which DMS's `Entry` needs.
*>
fn String? render_state(Allocator allocator, clipboard::State* state)
{
	wire::Line line;
	line.begin(allocator);
	line.writer.begin_object()!;
	wire::key_bool(&line.writer, "enabled", true)!;
	line.writer.key("history")!;
	write_history(&line.writer, state)!;
	line.writer.end_object()!;
	return line.finish();
}

// The DMS `Config` (clipboard/types.go:19-26) the running service enforces.
fn String? render_config(Allocator allocator)
{
	wire::Line line;
	line.begin(allocator);
	json::JsonWriter* w = &line.writer;
	w.begin_object()!;
	wire::key_int(w, "maxHistory", HISTORY_ITEMS)!;
	wire::key_int(w, "maxEntrySize", (long)PAYLOAD_LIMIT)!;
	// DMS's 0 means "never auto-clear". Bleu's history is in memory, so it starts empty:
	// clearAtStartup is true in effect, and no pins are kept.
	wire::key_int(w, "autoClearDays", 0)!;
	wire::key_bool(w, "clearAtStartup", true)!;
	wire::key_bool(w, "disabled", false)!;
	wire::key_int(w, "maxPinned", 0)!;
	w.end_object()!;
	return line.finish();
}

// `{"deleted":N}`, DMS's reply to deleteEntries.
fn String? render_deleted(Allocator allocator, long count)
{
	wire::Line line;
	line.begin(allocator);
	line.writer.begin_object()!;
	wire::key_int(&line.writer, "deleted", count)!;
	line.writer.end_object()!;
	return line.finish();
}

// The newest state as a reply: the empty state when none has been published yet.
fn String ClipboardModule.reply_state(&self, Allocator allocator)
{
	if (try snapshot = self.service.latest())
	{
		defer snapshot.release();
		if (try line = render_state(allocator, &snapshot.value)) return line;
	}
	return EMPTY_STATE;
}

// Encodes the newest state for the `clipboard` topic.
fn String? encode_state(void* context, Allocator allocator)
{
	ClipboardModule* m                           = (ClipboardModule*)context;
	observe::Snapshot{clipboard::State}* snapshot = m.service.latest()!;
	defer snapshot.release();
	return render_state(allocator, &snapshot.value);
}

// Listener: runs on the service's thread. It only marks the pump dirty.
fn void on_state(void* context, observe::Snapshot{clipboard::State}* snapshot)
{
	contract::StatePump* pump = (contract::StatePump*)context;
	pump.notify();
}

// The history entry with `id`, copied into `out`. False when there is none.
fn bool find_entry(clipboard::State* state, ulong id, clipboard::Entry* out)
{
	foreach (&entry : state.history)
	{
		if (entry.id == id)
		{
			*out = *entry;
			return true;
		}
	}
	return false;
}

// The `id` parameter as an entry id. A negative number is refused, as DMS's `toEntryID` does.
fn ulong? entry_id(Object* params) @private
{
	long raw = params::param_int(params, "id")!;
	if (raw < 0) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "invalid entry id: %d", raw)~;
	return (ulong)raw;
}

// The `ids` member as entry ids (clipboard/handlers.go:113-134 and `toEntryID`).
fn ulong[]? entry_ids(Object* params, Allocator allocator) @private
{
	Object* raw = params.get("ids") ?? null;
	if (!raw) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "missing 'ids' parameter")~;
	if (!raw.is_array()) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "'ids' must be an array")~;
	List{ulong} out;
	out.init(allocator);
	for (sz i = 0; i < raw.get_len(); i++)
	{
		Object* item = raw.get_at(i);
		if (!item.is_int() && !item.is_float()) return invalid_id()~;
		double value = item.is_int() ? (double)item.i : item.f;
		if (value < 0 || (double)(ulong)value != value) return invalid_id()~;
		out.push((ulong)value);
	}
	return out.to_aligned_array(allocator);
}

fn fault invalid_id() @private
{
	return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "invalid entry id");
}

// The ids of every entry in the history now, in `allocator`.
fn ulong[]? history_ids(clipboard::Clipboard* service, Allocator allocator) @private
{
	observe::Snapshot{clipboard::State}* snapshot = service.latest()!;
	defer snapshot.release();
	List{ulong} ids;
	ids.init(allocator);
	foreach (&entry : snapshot.value.history) ids.push(entry.id);
	return ids.to_aligned_array(allocator);
}

// The bytes of `mime` of `entry`, read from the history or from the live owner, copied into `allocator`.
fn char[]? fetch_bytes(clipboard::Clipboard* service, clipboard::Entry entry, String mime, Allocator allocator)
{
	operation::Operation{clipboard::Bytes}* op = service.fetch(entry, mime)!;
	defer op.release();
	char[] data = op.wait(OPERATION_TIMEOUT)!;
	return alloc::clone_slice(allocator, data);
}

// Remove one history entry. True when it was there.
fn bool remove_entry(clipboard::Clipboard* service, ulong id) @private
{
	clipboard::Entry entry = { .id = id };
	operation::Operation{bool}* op = service.delete(entry)!;
	defer op.release();
	return op.wait(OPERATION_TIMEOUT)!;
}

// `clipboard.getEntry {id}`: the entry with its payload, or `null` when it is gone (DMS's nil reply).
fn String? entry_line(ClipboardModule* m, Allocator allocator, ulong id) @private
{
	observe::Snapshot{clipboard::State}* snapshot = m.service.latest()!;
	defer snapshot.release();
	clipboard::Entry entry;
	if (!find_entry(&snapshot.value, id, &entry)) return "null";
	char[] data = fetch_bytes(m.service, entry, primary_mime(entry.mime_types), tmem)!;
	wire::Line line;
	line.begin(allocator);
	write_entry(&line.writer, &entry, data)!;
	return line.finish();
}

// `clipboard.copyEntry {id}`: own the selection with the entry's payload (`textOnly` has no alternate type to choose here).
fn void? copy_entry(ClipboardModule* m, ipc::Call* call) @private
{
	ulong id = entry_id(call.params)!;
	observe::Snapshot{clipboard::State}* snapshot = m.service.latest()!;
	defer snapshot.release();
	clipboard::Entry entry;
	if (!find_entry(&snapshot.value, id, &entry))
	{
		return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "entry not found: %d", id)~;
	}
	String mime = primary_mime(entry.mime_types);
	char[] data = fetch_bytes(m.service, entry, mime, tmem)!;
	clipboard::Representation[1] offered = { { .mime = mime, .bytes = data } };
	operation::Operation{ulong}* op = m.service.set(clipboard::Slot.CLIPBOARD, offered[..])!;
	defer op.release();
	op.wait(OPERATION_TIMEOUT)!;
	wire::respond_success(call, "copied to clipboard")!;
}

// `clipboard.paste`: the current selection's text (DMS's PasteText reads it; nothing is typed).
fn void? paste_text(ClipboardModule* m, ipc::Call* call) @private
{
	observe::Snapshot{clipboard::State}* snapshot = m.service.latest()!;
	defer snapshot.release();
	clipboard::Selection* current = &snapshot.value.current;
	String mime = text_type(current.mime_types);
	if (!current.present || mime == "")
	{
		return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no text on the clipboard")~;
	}
	clipboard::Entry entry = { .id = current.seq, .mime_types = current.mime_types };
	char[] data = fetch_bytes(m.service, entry, mime, tmem)!;
	wire::Line line;
	line.begin(tmem);
	line.writer.begin_object()!;
	wire::key_string(&line.writer, "text", (String)data)!;
	line.writer.end_object()!;
	call.respond_raw(line.finish()!);
}

// `clipboard.copy {text}`: own the selection with UTF-8 text.
fn void? copy_text(ClipboardModule* m, ipc::Call* call) @private
{
	String text = params::param_string(call.params, "text")!;
	operation::Operation{ulong}* op = m.service.set_text(clipboard::Slot.CLIPBOARD, text)!;
	defer op.release();
	op.wait(OPERATION_TIMEOUT)!;
	wire::respond_success(call, "copied to clipboard")!;
}

// `clipboard.deleteEntries {ids}`: remove each, and count those that were there.
fn void? delete_entries(ClipboardModule* m, ipc::Call* call) @private
{
	ulong[] ids = entry_ids(call.params, tmem)!;
	long deleted = 0;
	foreach (id : ids)
	{
		if (remove_entry(m.service, id)!) deleted++;
	}
	call.respond_raw(render_deleted(tmem, deleted)!);
}

// `clipboard.clearHistory`: remove every entry.
fn void? clear_history(ClipboardModule* m, ipc::Call* call) @private
{
	ulong[] ids = history_ids(m.service, tmem)!;
	foreach (id : ids) remove_entry(m.service, id)!;
	wire::respond_success(call, "history cleared")!;
}

// `clipboard.setConfig`: the running limits cannot change, so a request that names another value is refused.
fn void? set_config(ClipboardModule* m, ipc::Call* call) @private
{
	if (params::opt_int(call.params, "maxHistory", HISTORY_ITEMS) != HISTORY_ITEMS) return fixed("maxHistory")~;
	if (params::opt_int(call.params, "maxEntrySize", (long)PAYLOAD_LIMIT) != (long)PAYLOAD_LIMIT) return fixed("maxEntrySize")~;
	if (params::opt_int(call.params, "autoClearDays", 0) != 0) return fixed("autoClearDays")~;
	if (!params::opt_bool(call.params, "clearAtStartup", true)) return fixed("clearAtStartup")~;
	if (params::opt_bool(call.params, "disabled", false)) return fixed("disabled")~;
	if (params::opt_int(call.params, "maxPinned", 0) != 0) return fixed("maxPinned")~;
	wire::respond_success(call, "config updated")!;
}

fn fault fixed(String key) @private
{
	return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "not supported: %s cannot change while the clipboard service runs", key);
}

<* Start the clipboard module, or report why not and return false. *>
fn bool start(contract::Context* context, contract::Module* self)
{
	clipboard::Options options = { .history_items = HISTORY_ITEMS, .payload_limit = PAYLOAD_LIMIT };
	clipboard::Clipboard* service;
	if (try opened = clipboard::open(context.allocator, options))
	{
		service = opened;
	}
	else
	{
		contract::warn("clipboard: not started: %s", contract::failure_text("no clipboard service"));
		return false;
	}
	ClipboardModule* m = alloc::new(context.allocator, ClipboardModule);
	m.service = service;
	ipc::Topic* topic = context.server.register_topic("clipboard")!!;
	context.server.register_method("clipboard.getState", &handle_get_state, m)!!;
	context.server.register_method("clipboard.getHistory", &handle_get_history, m)!!;
	context.server.register_method("clipboard.getEntry", &handle_get_entry, m)!!;
	context.server.register_method("clipboard.deleteEntry", &handle_delete_entry, m)!!;
	context.server.register_method("clipboard.deleteEntries", &handle_delete_entries, m)!!;
	context.server.register_method("clipboard.clearHistory", &handle_clear_history, m)!!;
	context.server.register_method("clipboard.copy", &handle_copy, m)!!;
	context.server.register_method("clipboard.copyEntry", &handle_copy_entry, m)!!;
	context.server.register_method("clipboard.paste", &handle_paste, m)!!;
	context.server.register_method("clipboard.pasteSupported", &handle_paste_supported, m)!!;
	context.server.register_method("clipboard.getConfig", &handle_get_config, m)!!;
	context.server.register_method("clipboard.setConfig", &handle_set_config, m)!!;
	replies::register_all(context.server, REFUSALS[..], &handle_refused)!!;
	m.state_pump.start("clipboard", topic, &encode_state, m)!!;
	m.watch_id = service.watch(&on_state, &m.state_pump);
	self.state = m;
	return true;
}

<* Stop the module: no more publications, then the service is closed. The server has stopped already. *>
fn void stop(contract::Context* context, contract::Module* self)
{
	ClipboardModule* m = (ClipboardModule*)self.state;
	m.service.unwatch(m.watch_id)!!;
	m.state_pump.stop();
	m.state_pump.free();
	m.service.close();
	alloc::free(context.allocator, m);
}

<* The module's descriptor for `main`. A global constant, so its slices point at static data. *>
const contract::Module DESCRIPTOR = {
	.name = "clipboard",
	.start = &start,
	.stop = &stop,
	.topics = TOPICS[..],
	.capabilities = CAPABILITIES[..]
};

fn contract::Module descriptor() => DESCRIPTOR;

fn void handle_get_state(void* context, ipc::Call* call)
{
	ClipboardModule* m = (ClipboardModule*)context;
	@pool()
	{
		call.respond_raw(m.reply_state(tmem));
	};
}

fn void handle_get_history(void* context, ipc::Call* call)
{
	ClipboardModule* m = (ClipboardModule*)context;
	@pool()
	{
		if (catch get_history(m, call)) call.respond_error(contract::failure_text("failed to read the clipboard history"));
	};
}

fn void? get_history(ClipboardModule* m, ipc::Call* call) @private
{
	observe::Snapshot{clipboard::State}* snapshot = m.service.latest()!;
	defer snapshot.release();
	wire::Line line;
	line.begin(tmem);
	write_history(&line.writer, &snapshot.value)!;
	call.respond_raw(line.finish()!);
}

fn void handle_get_entry(void* context, ipc::Call* call)
{
	ClipboardModule* m = (ClipboardModule*)context;
	@pool()
	{
		if (catch get_entry(m, call)) call.respond_error(contract::failure_text("failed to read the clipboard entry"));
	};
}

fn void? get_entry(ClipboardModule* m, ipc::Call* call) @private
{
	ulong id = entry_id(call.params)!;
	call.respond_raw(entry_line(m, tmem, id)!);
}

fn void handle_delete_entry(void* context, ipc::Call* call)
{
	ClipboardModule* m = (ClipboardModule*)context;
	@pool()
	{
		if (catch delete_entry(m, call)) call.respond_error(contract::failure_text("failed to delete the entry"));
	};
}

fn void? delete_entry(ClipboardModule* m, ipc::Call* call) @private
{
	ulong id = entry_id(call.params)!;
	if (!remove_entry(m.service, id)) return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "entry not found: %d", id)~;
	wire::respond_success(call, "entry deleted")!;
}

fn void handle_delete_entries(void* context, ipc::Call* call)
{
	ClipboardModule* m = (ClipboardModule*)context;
	@pool()
	{
		if (catch delete_entries(m, call)) call.respond_error(contract::failure_text("failed to delete the entries"));
	};
}

fn void handle_clear_history(void* context, ipc::Call* call)
{
	ClipboardModule* m = (ClipboardModule*)context;
	@pool()
	{
		if (catch clear_history(m, call)) call.respond_error(contract::failure_text("failed to clear the history"));
	};
}

fn void handle_copy(void* context, ipc::Call* call)
{
	ClipboardModule* m = (ClipboardModule*)context;
	@pool()
	{
		if (catch copy_text(m, call)) call.respond_error(contract::failure_text("failed to copy to the clipboard"));
	};
}

fn void handle_copy_entry(void* context, ipc::Call* call)
{
	ClipboardModule* m = (ClipboardModule*)context;
	@pool()
	{
		if (catch copy_entry(m, call)) call.respond_error(contract::failure_text("failed to copy the entry"));
	};
}

fn void handle_paste(void* context, ipc::Call* call)
{
	ClipboardModule* m = (ClipboardModule*)context;
	@pool()
	{
		if (catch paste_text(m, call)) call.respond_error(contract::failure_text("failed to read the clipboard"));
	};
}

// Bleu has no paste keystroke, so DMS's `pasteSupported` is false: the honest answer, not a refusal.
fn void handle_paste_supported(void* context, ipc::Call* call)
{
	call.respond_raw("{\"supported\":false}");
}

fn void handle_get_config(void* context, ipc::Call* call)
{
	@pool()
	{
		if (catch call.respond_raw(render_config(tmem))) call.respond_error(contract::failure_text("failed to read the config"));
	};
}

fn void handle_set_config(void* context, ipc::Call* call)
{
	ClipboardModule* m = (ClipboardModule*)context;
	@pool()
	{
		if (catch set_config(m, call)) call.respond_error(contract::failure_text("failed to set the config"));
	};
}

fn void handle_refused(void* context, ipc::Call* call)
{
	replies::answer(REFUSALS[..], call);
}
