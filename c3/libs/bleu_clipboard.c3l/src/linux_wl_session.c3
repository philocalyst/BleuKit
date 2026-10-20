<*
 One connection to the compositor's data-control protocol, used by the worker thread.

 The session binds a seat and a data-control manager, makes a device for the seat, and
 keeps track of the two selections: the offer each one currently is, and our own source
 when this service owns it. Events arrive through the device, offer and source listeners
 and update the platform-neutral `Board`. Pipe transfers (reading an offer, serving our
 source) are in `linux_wl_transfer.c3`; the poll loop is `pump` below.

 Threading: one thread owns the session. Listeners run inside `pump`, on that thread.
*>
module bleu::clipboard::linux_wl @feat(LINUX);
import bleu::clipboard, bleu::error, bleu::rt, bleu::rt::poller, bleu::rt::wakeup, bleu::wl, bleu::wl::display, bleu::wl::proto::wayland, bleu::wl::proto::ext_data_control, bleu::wl::proto::wlr_data_control, std::collections::list, std::collections::maybe, std::time, std::core::mem;

<* Most transfers in flight at once. A further fetch is refused as BUSY. *>
const usz MAX_TRANSFERS = 8;
<* Poller tag of the display socket. *>
const usz CLIENT_TAG = 0;
<* Poller tag of transfer `i` is `TRANSFER_TAG + i`. *>
const usz TRANSFER_TAG = 1;
<* Poller sources: the socket and every transfer. The wake-up is added by the poller itself. *>
const usz POLLER_CAPACITY = 1 + MAX_TRANSFERS;
<* How long `pump` waits when nothing is due: 1 s. Commands and socket traffic end the wait sooner. *>
const Duration IDLE_WAIT = (Duration)1_000_000;

<* An offer from another application: its MIME types, and the object that can be asked for them. *>
struct WlOffer
{
	display::Proxy* object;
	DynamicArenaAllocator arena;
	List{String} mimes;
}

<*
 A source this service owns: the bytes it serves, by MIME type. `current` is false once
 another source replaced it; the compositor then sends `cancelled`, and the record goes.
*>
struct WlSource
{
	WlSession* session;
	display::Proxy* object;
	DynamicArenaAllocator arena;
	Slot slot;
	bool current;
	String[] mimes;
	Representation[] representations;
}

<* The session. `init` once, then `connect_env` or `connect_fd`; `disconnect` releases everything. *>
struct WlSession
{
	Allocator allocator;
	Board* board;
	Duration timeout;
	wakeup::Wakeup* wakeup;
	wl::Client client;
	bool connected;
	DataControl kind;
	display::Proxy* manager;
	display::Proxy* device;
	bool primary_supported;
	bool finished;
	WlOffer*[2] lane_offers;
	List{WlOffer*} offers;
	List{WlSource*} sources;
	WlTransfer[MAX_TRANSFERS] transfers;
	poller::Poller poller;
	bool poller_ready;
	bool[2] selection_changed;
	bool[2] ownership_lost;
}

<*
 Prepare an empty session. `board` must outlive it. `wakeup` is the worker's wake-up and is
 used once the poll loop starts.
*>
fn void WlSession.init(&self, Allocator allocator, Board* board, Duration timeout)
{
	*self = { .allocator = allocator, .board = board, .timeout = timeout };
	self.offers.init(allocator, 8);
	self.sources.init(allocator, 4);
}

<* Connect to the compositor named by the environment, then bind the data-control objects. *>
fn void? WlSession.connect_env(&self)
{
	self.client.connect_env(self.allocator)!;
	self.bind_all()!;
}

<*
 Connect over an already connected descriptor (a socket pair in tests). The session owns
 it from success on.
*>
fn void? WlSession.connect_fd(&self, rt::Native fd)
{
	self.client.init(self.allocator, fd)!;
	self.bind_all()!;
}

<*
 Learn the globals, bind the seat and a manager (ext first, wlr second), make the device,
 and switch the socket to non-blocking for the poll loop. On failure the client is closed.

 @return? error::UNAVAILABLE : "The compositor has no seat, or no data-control manager"
*>
fn void? WlSession.bind_all(&self)
{
	if (catch err = self.try_bind_all())
	{
		self.client.close();
		return err~;
	}
	self.connected = true;
}

fn void? WlSession.try_bind_all(&self)
{
	self.client.roundtrip()!;
	Global[] globals = self.client.globals_view();
	Maybe{Global} seat = find_global(globals, wayland::WL_SEAT.name);
	if (!seat.has_value) return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "no wl_seat global")~;
	Maybe{Global} ext = find_global(globals, ext_data_control::EXT_DATA_CONTROL_MANAGER_V1.name);
	if (ext.has_value)
	{
		self.kind = DataControl.EXT;
		self.manager = self.client.bind(ext.value, ext_data_control::EXT_DATA_CONTROL_MANAGER_V1)!;
	}
	else
	{
		Maybe{Global} wlr = find_global(globals, WLR_MANAGER_NAME);
		if (!wlr.has_value)
		{
			return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "no data-control manager global")~;
		}
		self.kind = DataControl.WLR;
		self.manager = self.client.bind(wlr.value, wlr_data_control::ZWLR_DATA_CONTROL_MANAGER_V1)!;
	}
	display::Proxy* seat_proxy = self.client.bind(seat.value, wayland::WL_SEAT)!;
	self.device = proto_get_device(self.kind, self.manager, seat_proxy)!;
	proto_listen_device(self.kind, self.device, self);
	self.primary_supported = self.kind == DataControl.EXT || self.device.version >= WLR_PRIMARY_VERSION;
	self.client.conn.set_nonblocking(true)!;
}

// The advertised global with this interface name, if there is one.
fn Maybe{Global} find_global(Global[] globals, String interface_name)
{
	foreach (global : globals)
	{
		if (global.interface_name == interface_name) return maybe::value(global);
	}
	return { };
}

<* Release every offer, source, transfer and the connection. The session can be connected again. *>
fn void WlSession.disconnect(&self)
{
	for (usz i = 0; i < MAX_TRANSFERS; i++)
	{
		if (self.transfers[i].active) self.abort_transfer(i, error::DISCONNECTED);
	}
	while (!self.offers.is_empty())
	{
		WlOffer* offer = self.offers.get(0);
		self.offers.remove_at(0);
		offer.arena.free();
		alloc::free(self.allocator, offer);
	}
	while (!self.sources.is_empty())
	{
		WlSource* source = self.sources.get(0);
		self.sources.remove_at(0);
		source.arena.free();
		alloc::free(self.allocator, source);
	}
	self.lane_offers = { null, null };
	if (self.connected) self.client.close();
	self.connected = false;
	self.finished = false;
	if (self.poller_ready) self.poller.free();
	self.poller_ready = false;
}

<* Disconnect and free the session's lists. The session must not be used afterwards. *>
fn void WlSession.free(&self)
{
	self.disconnect();
	self.offers.free();
	self.sources.free();
}

<* Whether the compositor retired the device, which ends the session. *>
fn bool WlSession.is_finished(&self) => self.finished;

// ---- Offers from other applications ----------------------------------------------

<* The device announced an offer. Its MIME types follow, then the `selection` event that names it. *>
fn void device_data_offer(WlSession* session, display::Proxy* object)
{
	WlOffer* offer = alloc::new(session.allocator, WlOffer);
	offer.object = object;
	offer.arena.init(session.allocator, clipboard::ARENA_PAGE);
	offer.mimes.init(&offer.arena, 8);
	session.offers.push(offer);
	proto_listen_offer(session.kind, object, offer);
}

<* One MIME type of an offer. Invalid and surplus types are dropped here, as the board drops them. *>
fn void offer_mime(WlOffer* offer, String mime)
{
	if (offer.mimes.len() < (sz)clipboard::MAX_MIME_TYPES && clipboard::is_valid_mime(mime)) offer.mimes.push(mime.copy(&offer.arena));
}

<*
 The clipboard or primary selection now belongs to `object` (null: nobody). Ours is ignored,
 because the board already holds it; another application's content is read for text.
*>
fn void device_selection(WlSession* session, Slot slot, display::Proxy* object)
{
	WlOffer* offer = object == null ? null : (WlOffer*)object.context;
	WlOffer* previous = session.lane_offers[slot.ordinal];
	session.lane_offers[slot.ordinal] = offer;
	if (previous != null && previous != offer) session.destroy_offer(previous);
	session.selection_changed[slot.ordinal] = true;
	if (offer == null)
	{
		session.board.clear(slot);
		return;
	}
	WlSource* own = session.current_source(slot);
	if (own != null && same_mimes(own.mimes, offer.mimes.array_view()))
	{
		session.lane_offers[slot.ordinal] = null;
		session.destroy_offer(offer);
		return;
	}
	ulong seq = session.board.replace(slot, offer.mimes.array_view(), false);
	Maybe{String} text = session.board.text_to_read(slot);
	// A copy whose text cannot be read is still shown, just without a preview.
	if (text.has_value)
	{
		if (catch err = session.start_receive(offer, slot, seq, text.value, null)) {}
	}
}

// Whether the owner's offer lists exactly the types we offered, in any order.
fn bool same_mimes(String[] ours, String[] theirs)
{
	if (ours.len != theirs.len) return false;
	foreach (mime : theirs)
	{
		if (!contains_mime(ours, mime)) return false;
	}
	return true;
}

fn bool contains_mime(String[] values, String wanted)
{
	foreach (value : values)
	{
		if (value == wanted) return true;
	}
	return false;
}

<* The device was retired by the compositor: nothing is selected any more. *>
fn void device_finished(WlSession* session)
{
	session.finished = true;
	session.board.clear(Slot.CLIPBOARD);
	session.board.clear(Slot.PRIMARY);
	session.selection_changed = { true, true };
}

// Destroy an offer object and free its record. Its events stop. Its record is in `offers`.
fn void WlSession.destroy_offer(&self, WlOffer* offer)
{
	if (!self.finished)
	{
		if (catch err = proto_destroy_offer(self.kind, offer.object)) {}
	}
	self.offers.remove_at(index_of_offer(&self.offers, offer));
	offer.arena.free();
	alloc::free(self.allocator, offer);
}

fn sz index_of_offer(List{WlOffer*}* offers, WlOffer* wanted)
{
	foreach (i, offer : offers.array_view())
	{
		if (offer == wanted) return (sz)i;
	}
	return -1;
}

// ---- Our own sources ---------------------------------------------------------------

<*
 Own `slot` with `representations`: a new source offers each MIME type and becomes the
 selection, and the board records it as owned. A text type is kept in the history
 unless a privacy marker is among the types.

 @return "The selection's sequence number"
 @return? error::UNSUPPORTED : "The primary selection needs a compositor that supports it"
*>
fn ulong? WlSession.own(&self, Slot slot, Representation[] representations)
{
	WlSource* source = alloc::new(self.allocator, WlSource);
	source.arena.init(self.allocator, clipboard::ARENA_PAGE);
	source.session = self;
	source.slot = slot;
	source.representations = alloc::alloc_array(&source.arena, Representation, representations.len);
	String[] mimes = alloc::alloc_array(&source.arena, String, representations.len);
	foreach (i, representation : representations)
	{
		source.representations[i] = { .mime = representation.mime.copy(&source.arena), .bytes = alloc::clone_slice(&source.arena, representation.bytes) };
		mimes[i] = source.representations[i].mime;
	}
	source.mimes = clipboard::sanitise_offer(&source.arena, mimes);
	source.object = proto_create_source(self.kind, self.manager)!;
	proto_listen_source(self.kind, source.object, source);
	foreach (mime : source.mimes) proto_source_offer(self.kind, source.object, mime)!;
	WlSource* previous = self.current_source(slot);
	if (previous != null) previous.current = false;
	source.current = true;
	self.sources.push(source);
	proto_set_selection(self.kind, self.device, source.object, slot)!;
	return self.record_own(slot, source);
}

// Record in the board that `slot` is now our `source`, and keep its text in the history.
fn ulong WlSession.record_own(&self, Slot slot, WlSource* source)
{
	ulong seq = self.board.replace(slot, source.mimes, true);
	Privacy privacy = clipboard::privacy_of(source.mimes);
	foreach (representation : source.representations)
	{
		if (privacy == Privacy.OPEN && is_text_mime(representation.mime))
		{
			self.board.captured(slot, seq, representation.mime, representation.bytes);
			break;
		}
	}
	self.selection_changed[slot.ordinal] = true;
	return seq;
}

// Whether `mime` is one of the text types the board reads.
fn bool is_text_mime(String mime) => clipboard::choose_text_type({ mime }).has_value;

<* Release `slot`: nothing is selected, and our source (if any) is told it was replaced. *>
fn bool WlSession.clear(&self, Slot slot)
{
	WlSource* own = self.current_source(slot);
	bool held = own != null || self.board.lane(slot).present;
	if (own != null) own.current = false;
	if (slot == Slot.CLIPBOARD || self.primary_supported)
	{
		if (catch err = proto_set_selection(self.kind, self.device, null, slot)) {}
	}
	self.board.clear(slot);
	self.selection_changed[slot.ordinal] = true;
	return held;
}

// The source that currently owns `slot`, or null.
fn WlSource* WlSession.current_source(&self, Slot slot)
{
	foreach (source : self.sources.array_view())
	{
		if (source.current && source.slot == slot) return source;
	}
	return null;
}

<* The compositor replaced one of our sources; its record is released. *>
fn void source_cancelled(WlSource* source)
{
	WlSession* session = source.session;
	if (source.current) session.ownership_lost[source.slot.ordinal] = true;
	source.current = false;
	session.sources.remove_at(index_of_source(&session.sources, source));
	if (!session.finished)
	{
		if (catch err = proto_destroy_source(session.kind, source.object)) {}
	}
	source.arena.free();
	alloc::free(session.allocator, source);
}

fn sz index_of_source(List{WlSource*}* sources, WlSource* wanted)
{
	foreach (i, source : sources.array_view())
	{
		if (source == wanted) return (sz)i;
	}
	return -1;
}

// ---- Event lists for the worker ----------------------------------------------------

<* Whether `slot` changed since the last call, and forget it. *>
fn bool WlSession.take_selection_changed(&self, Slot slot)
{
	bool changed = self.selection_changed[slot.ordinal];
	self.selection_changed[slot.ordinal] = false;
	return changed;
}

<* Whether `slot` lost our ownership since the last call, and forget it. *>
fn bool WlSession.take_ownership_lost(&self, Slot slot)
{
	bool lost = self.ownership_lost[slot.ordinal];
	self.ownership_lost[slot.ordinal] = false;
	return lost;
}

// ---- The poll loop ---------------------------------------------------------------

<*
 Wait up to `timeout` (less when a transfer times out first) for the socket or a transfer,
 then serve what is ready: dispatch events, read transfers, expire the late ones, and flush
 requests. Returns when something happened or the wait ended.

 @return? error::DISCONNECTED, error::PROTOCOL, error::BACKEND_FAILURE : "The connection failed"
*>
fn void? WlSession.pump(&self, Duration timeout)
{
	self.ensure_poller()!;
	self.register_sources()!;
	Duration wait = timeout;
	for (usz i = 0; i < MAX_TRANSFERS; i++)
	{
		if (!self.transfers[i].active) continue;
		Duration left = self.transfers[i].deadline.remaining();
		if (left < wait) wait = left;
	}
	poller::Ready[] ready = wait_ready(&self.poller, wait)!;
	foreach (event : ready)
	{
		if (event.tag == CLIENT_TAG)
		{
			if (event.events.writable) self.client.flush()!;
			if (event.events.readable || event.events.hangup || event.events.failed)
			{
				while (self.client.dispatch()! > 0) {}
			}
		}
		else if (event.tag >= TRANSFER_TAG && event.tag < TRANSFER_TAG + MAX_TRANSFERS)
		{
			self.service_transfer((usz)(event.tag - TRANSFER_TAG));
		}
	}
	self.expire_transfers();
	self.client.flush()!;
}

// Poller.wait, where a timeout is not an error: nothing became ready in time.
fn poller::Ready[]? wait_ready(poller::Poller* waiter, Duration timeout)
{
	if (try ready = waiter.wait(timeout)) return ready;
	return { };
}

fn void? WlSession.ensure_poller(&self)
{
	if (self.poller_ready) return;
	self.poller.init(self.allocator, self.wakeup, POLLER_CAPACITY)!;
	self.poller_ready = true;
}

// Rebuild the poller's source list: the socket, every active transfer, with the current interest.
fn void? WlSession.register_sources(&self)
{
	if (catch self.poller.remove(CLIENT_TAG)) {}
	poller::Interest socket;
	socket.readable = true;
	socket.writable = self.client.wants_write();
	self.poller.add({ .handle = self.client.native(), .interest = socket, .tag = CLIENT_TAG })!;
	for (usz i = 0; i < MAX_TRANSFERS; i++)
	{
		if (catch self.poller.remove(TRANSFER_TAG + i)) {}
		if (!self.transfers[i].active) continue;
		poller::Interest reading;
		reading.readable = true;
		self.poller.add({ .handle = self.transfers[i].fd, .interest = reading, .tag = TRANSFER_TAG + i })!;
	}
}
