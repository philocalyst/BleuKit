<*
 The clipboard service: read and own the clipboard and the primary selection, keep the text
 copied recently, and fetch any offered type on demand.

 Clipboard* clipboard = clipboard::open(mem)!;
 defer clipboard.close();
 Operation{ulong}* set = clipboard.set_text(CLIPBOARD, "hello")!;
 defer set.release();
 set.wait(time::sec(2))!;

 Payload bytes never appear in the state or the events: `fetch` returns them in an operation.
 Every method may be called from any thread.
*>
module bleu::clipboard;
import std::collections::enummap, std::time, bleu::error, bleu::availability, bleu::observe, bleu::stream, bleu::service, bleu::operation;

alias ClipboardHub = Hub{State, Command, Event};
alias Capabilities = EnumMap{Cap, Availability};

<* How long one pipe transfer or one served write may take: 2 s. *>
const Duration DEFAULT_TRANSFER_TIMEOUT = (Duration)2_000_000;

<*
 How `open` finds and tunes a backend. Zero means the default for every number and time.
*>
struct Options
{
	Backend backend; // AUTO tries every backend of the platform in priority order
	uint history_items; // text copies kept; default 50
	usz history_bytes; // bytes of text kept in the history; default 4 MiB
	usz payload_limit; // largest payload read or stored; default 1 MiB
	Duration transfer_timeout; // one transfer or one served write; default 2 s
}

<* The service: the hub, the backend, and the capabilities. *>
struct Clipboard
{
	Allocator allocator;
	ClipboardHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
	usz payload_limit;
}

<*
 Open the first working backend of this platform (or the one in `options`).

 @param allocator : "Allocator for the service and its snapshots"
 @return? error::UNAVAILABLE : "No clipboard is reachable here (no display, no data-control protocol)"
 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
*>
fn Clipboard*? open(Allocator allocator, Options options = { })
{
	Options resolved = resolve(options);
	Driver* driver   = select_driver(resolved)!;
	Clipboard* self  = alloc::new(allocator, Clipboard);
	self.allocator = allocator;
	self.driver = driver;
	self.payload_limit = resolved.payload_limit;
	self.driver_state = driver.create(allocator, resolved, &self.capabilities)!;
	if (catch err = self.hub.start(allocator, "clipboard", driver.info.name, driver.run, self.driver_state))
	{
		driver.destroy(allocator, self.driver_state);
		alloc::free(allocator, self);
		return err~;
	}
	return self;
}

// The options with every zero replaced by its default.
fn Options resolve(Options options) @private
{
	if (options.history_items == 0) options.history_items = DEFAULT_HISTORY_ITEMS;
	if (options.history_bytes == 0) options.history_bytes = DEFAULT_HISTORY_BYTES;
	if (options.payload_limit == 0) options.payload_limit = DEFAULT_PAYLOAD_LIMIT;
	if (options.transfer_timeout == time::DURATION_ZERO) options.transfer_timeout = DEFAULT_TRANSFER_TIMEOUT;
	return options;
}

<* Stop the backend and release everything. Operations still held by callers stay valid until released. *>
fn void Clipboard.close(&self)
{
	self.hub.stop();
	self.driver.destroy(self.allocator, self.driver_state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend in use, for diagnostics ("wayland"). *>
fn String Clipboard.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Clipboard.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The backend has not produced its first reading yet"
*>
fn Snapshot{State}*? Clipboard.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`, then pass the previous
 snapshot's `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn Snapshot{State}*? Clipboard.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later state. Quick and non-blocking only. *>
fn WatchId{State} Clipboard.watch(
	&self,
	Listener{State} listener,
	void* context
) => self.hub.state.watch(listener, context);

<* Remove a listener; when this returns it is not running. Not from inside a listener. *>
fn void Clipboard.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<* Subscribe to transient events (a selection changed, ownership was lost). *>
fn Reader{Event}*? Clipboard.subscribe(&self) => self.hub.events.subscribe();

<*
 Own `slot` with text. The text is offered as UTF-8 and as UTF8_STRING. The operation completes
 with the sequence number of the new selection.

 @return? error::INVALID_ARGUMENT : "The text is larger than the payload limit"
 @return? error::UNAVAILABLE : "The queue is full or the service is closing"
*>
fn Operation{ulong}*? Clipboard.set_text(&self, Slot slot, String text)
{
	Representation[2] offered = {
		{ .mime = "text/plain;charset=utf-8", .bytes = (char[])text },
		{ .mime = "UTF8_STRING", .bytes = (char[])text },
	};
	return self.set(slot, offered[..]);
}

<*
 Own `slot` with `representations`, one MIME type each. The operation completes with the new
 selection's sequence number. Other applications read the bytes through the protocol until
 another copy replaces this one.

 @return? error::INVALID_ARGUMENT : "No types, an invalid type name, or a payload over the limit"
 @return? error::UNSUPPORTED : "The primary selection needs a compositor that supports it"
 @return? error::UNAVAILABLE : "The queue is full or the service is closing"
*>
fn Operation{ulong}*? Clipboard.set(&self, Slot slot, Representation[] representations)
{
	check_representations(representations, self.payload_limit)!;
	Operation{ulong}* op = operation::begin{ulong}(self.allocator);
	Command command = {
		.kind = CommandKind.SET,
		.slot = slot,
		.representations = copy_representations(op.allocator(), representations),
	};
	command.operation = (void*)op.retain();
	if (catch err = self.hub.post(command))
	{
		op.release();
		op.release();
		return err~;
	}
	return op;
}

<*
 Release `slot` if this service owns it. The operation completes with `true` when there was a
 selection to release.

 @return? error::UNAVAILABLE : "The queue is full or the service is closing"
*>
fn Operation{bool}*? Clipboard.clear(&self, Slot slot)
{
	Operation{bool}* op = operation::begin{bool}(self.allocator);
	Command command     = { .kind = CommandKind.CLEAR, .slot = slot };
	command.operation = (void*)op.retain();
	if (catch err = self.hub.post(command))
	{
		op.release();
		op.release();
		return err~;
	}
	return op;
}

<*
 Read `mime` of a copy: from the history when the entry holds that type, otherwise from the
 live owner of the current selection (with the size cap and the timeout). The operation holds
 the bytes until it is released.

 @return? error::INVALID_ARGUMENT : "The type name is not valid"
 @return? error::UNAVAILABLE : "The copy is gone, or the queue is full or the service is closing"
 @return? error::OUT_OF_RANGE : "The payload is over the limit"
*>
fn Operation{Bytes}*? Clipboard.fetch(&self, Entry entry, String mime)
{
	if (!is_valid_mime(mime)) return error::INVALID_ARGUMENT~;
	Operation{Bytes}* op = operation::begin{Bytes}(self.allocator);
	Command command      = { .kind = CommandKind.FETCH, .id = entry.id, .mime = mime.copy(op.allocator()) };
	command.operation = (void*)op.retain();
	if (catch err = self.hub.post(command))
	{
		op.release();
		op.release();
		return err~;
	}
	return op;
}

<*
 Remove `entry` from the history. The operation completes with `true` when it was there.

 @return? error::UNAVAILABLE : "The queue is full or the service is closing"
*>
fn Operation{bool}*? Clipboard.delete(&self, Entry entry)
{
	Operation{bool}* op = operation::begin{bool}(self.allocator);
	Command command     = { .kind = CommandKind.DELETE, .id = entry.id };
	command.operation = (void*)op.retain();
	if (catch err = self.hub.post(command))
	{
		op.release();
		op.release();
		return err~;
	}
	return op;
}

<*
 Reject a set that could not be offered: no types, a bad name, or more bytes than the limit.

 @return? error::INVALID_ARGUMENT : "See above"
*>
fn void? check_representations(Representation[] representations, usz payload_limit) @private
{
	if (representations.len == 0 || representations.len > MAX_MIME_TYPES) return error::INVALID_ARGUMENT~;
	foreach (representation : representations)
	{
		if (!is_valid_mime(representation.mime)) return error::INVALID_ARGUMENT~;
		if ((usz)representation.bytes.len > payload_limit) return error::INVALID_ARGUMENT~;
	}
}

<* A deep copy of `representations` into `allocator`, so the operation owns it. *>
fn Representation[] copy_representations(Allocator allocator, Representation[] representations) @private
{
	Representation[] copies = alloc::alloc_array(allocator, Representation, representations.len);
	foreach (i, representation : representations)
	{
		copies[i] = {
			.mime = representation.mime.copy(allocator),
			.bytes = alloc::clone_slice(allocator, representation.bytes)
		};
	}
	return copies;
}