<*
 The bookkeeping every platform backend shares: the two selections as the worker last
 saw them, and the bounded history of text copies. Platform code reports what it sees
 (an owner's types, the bytes it read) and asks what to publish. Pure: it never calls the
 OS. Owned by one thread (the worker), so it has no lock.

 Memory: each selection and each history item owns a dynamic arena, so replacing or
 evicting one frees all of its strings and bytes at once. The history is bounded by item
 count and by total bytes; the oldest items go first.
*>
module bleu::clipboard;
import std::collections::list, std::collections::maybe, std::time;

<* Text copies kept when the caller asks for no particular number. *>
const uint DEFAULT_HISTORY_ITEMS = 50;
<* Total bytes of text kept in the history when the caller asks for no particular size: 4 MiB. *>
const usz DEFAULT_HISTORY_BYTES  = 4 * 1024 * 1024;
<* Largest payload read or kept: 1 MiB. Larger offers are described, not read. *>
const usz DEFAULT_PAYLOAD_LIMIT  = 1024 * 1024;
<* Page size of the arenas that hold selections and history items. *>
const usz ARENA_PAGE             = 1024;

<* One selection. Its arena holds every string it refers to. *>
struct Lane
{
	DynamicArenaAllocator arena;
	bool present;
	bool owned;
	ulong seq;
	Privacy privacy;
	String[] mime_types;
	String preview;
	usz size;
}

<* One history item. Its arena holds the strings and the bytes. *>
struct Item
{
	DynamicArenaAllocator arena;
	ulong id;
	Time time;
	String mime;
	String[] mime_types;
	String preview;
	char[] bytes;
}

<* The bookkeeping itself. `init` before use and `free` when done; do not move it after `init`. *>
struct Board
{
	Allocator allocator;
	Lane[2] lanes;
	List{Item*} items; // oldest first
	usz items_max;
	usz bytes_max;
	usz payload_limit;
	usz total_bytes;
}

<*
 @param items_max : "Most history items kept"
 @param bytes_max : "Most bytes of text kept in the history"
 @param payload_limit : "Largest payload a platform may read into the board"
*>
fn void Board.init(&self, Allocator allocator, uint items_max, usz bytes_max, usz payload_limit)
{
	self.allocator = allocator;
	foreach (&lane : self.lanes) lane.arena.init(allocator, ARENA_PAGE);
	self.items.init(allocator, 16);
	self.items_max = items_max;
	self.bytes_max = bytes_max;
	self.payload_limit = payload_limit;
	self.total_bytes = 0;
}

<* Release every selection and history item. *>
fn void Board.free(&self)
{
	while (self.items.len() > 0) self.drop_item(0);
	self.items.free();
	foreach (&lane : self.lanes) lane.arena.free();
}

<* The lane of `slot`. *>
fn Lane* Board.lane(&self, Slot slot) @inline => &self.lanes[slot.ordinal];

<*
 Record that `slot` now belongs to an owner who offers `offered`, replacing whatever it held.
 Clears the preview: the new content is not read yet. An empty or wholly invalid offer
 leaves the selection empty.

 @param owned : "true when this service is the owner"
 @return "The new sequence number of the selection; it names the history entry this copy makes"
*>
fn ulong Board.replace(&self, Slot slot, String[] offered, bool owned)
{
	Lane* lane = self.lane(slot);
	lane.arena.free();
	lane.arena.init(self.allocator, ARENA_PAGE);
	lane.seq += 1;
	lane.owned = owned;
	lane.mime_types = sanitise_offer(&lane.arena, offered);
	lane.present = lane.mime_types.len > 0;
	lane.privacy = lane.present ? privacy_of(lane.mime_types) : Privacy.OPEN;
	lane.preview = "";
	lane.size = 0;
	return lane.seq;
}

<* Forget the selection of `slot`: it is empty, and its sequence number moves on. *>
fn void Board.clear(&self, Slot slot)
{
	self.replace(slot, { }, false);
}

<*
 The text type that a platform should read for `slot`, or nothing. Nothing when the
 selection is empty, has a privacy marker (its bytes must not be read), or offers no text.
*>
fn Maybe{String} Board.text_to_read(&self, Slot slot)
{
	Lane* lane = self.lane(slot);
	if (!lane.present || lane.privacy != Privacy.OPEN) return { };
	return choose_text_type(lane.mime_types);
}

<*
 Record the bytes that were read for selection `seq` of `slot`, of type `mime`. A stale
 `seq` (the selection changed meanwhile) or a payload over the limit is ignored. The
 clipboard's text is then kept in the history, unless it is over the history's byte budget.
*>
fn void Board.captured(&self, Slot slot, ulong seq, String mime, char[] bytes)
{
	Lane* lane = self.lane(slot);
	if (!lane.present || lane.seq != seq || lane.privacy != Privacy.OPEN) return;
	if ((usz)bytes.len > self.payload_limit) return;
	lane.preview = make_preview(&lane.arena, bytes);
	lane.size = (usz)bytes.len;
	if (slot == Slot.CLIPBOARD) self.remember(lane, mime, bytes);
}

<* Keep one copy in the history, moving an identical earlier copy to the top. Oldest items go first when over budget. *>
fn void Board.remember(&self, Lane* lane, String mime, char[] bytes)
{
	usz size = (usz)bytes.len;
	if (size == 0 || size > self.bytes_max) return;
	String text = (String)bytes;
	for (sz i = self.items.len() - 1; i >= 0; i--)
	{
		Item* earlier = self.items.get(i);
		if (earlier.mime == mime && (String)earlier.bytes == text) self.drop_item(i);
	}
	while (!self.items.is_empty()
		&& (self.items.len() >= (sz)self.items_max || self.total_bytes + size > self.bytes_max))
	{
		self.drop_item(0);
	}
	Item* item = alloc::new(self.allocator, Item);
	item.arena.init(self.allocator, ARENA_PAGE);
	item.id = lane.seq;
	item.time = time::now();
	item.mime = mime.copy(&item.arena);
	item.mime_types = copy_strings(&item.arena, lane.mime_types);
	item.preview = lane.preview.copy(&item.arena);
	item.bytes = alloc::clone_slice(&item.arena, bytes);
	self.items.push(item);
	self.total_bytes += size;
}

<* Remove the item at `index` and free it. *>
fn void Board.drop_item(&self, sz index)
{
	Item* item = self.items.get(index);
	self.total_bytes -= (usz)item.bytes.len;
	self.items.remove_at(index);
	item.arena.free();
	alloc::free(self.allocator, item);
}

<* The history item with this id, or null. The caller checks its `mime` and reads `bytes` at once. *>
fn Item* Board.find(&self, ulong id)
{
	foreach (item : self.items.array_view())
	{
		if (item.id == id) return item;
	}
	return null;
}

<*
 Remove the history item with this id.

 @return "true when an item was removed"
*>
fn bool Board.delete(&self, ulong id)
{
	foreach (i, item : self.items.array_view())
	{
		if (item.id == id)
		{
			self.drop_item((sz)i);
			return true;
		}
	}
	return false;
}

<*
 Write the published view into `state`. Every string and array in it is allocated in
 `allocator` (the snapshot's arena), so it outlives the board's own memory.
*>
fn void Board.build(&self, Allocator allocator, State* state)
{
	state.current = copy_selection(allocator, self.lane(Slot.CLIPBOARD));
	state.primary = copy_selection(allocator, self.lane(Slot.PRIMARY));
	Entry[] history = { };
	if (!self.items.is_empty()) history = alloc::alloc_array(allocator, Entry, self.items.len());
	usz count = (usz)history.len;
	foreach (i, item : self.items.array_view())
	{
		history[count - 1 - (usz)i] = {
			.id = item.id,
			.time = item.time,
			.mime_types = copy_strings(allocator, item.mime_types),
			.preview = item.preview.copy(allocator),
			.size = (usz)item.bytes.len,
		};
	}
	state.history = history;
}

// A deep copy of one lane, for a snapshot.
fn Selection copy_selection(Allocator allocator, Lane* lane) @private
{
	return {
		.present = lane.present,
		.owned = lane.owned,
		.seq = lane.seq,
		.mime_types = copy_strings(allocator, lane.mime_types),
		.privacy = lane.privacy,
		.preview = lane.preview.copy(allocator),
		.size = lane.size,
	};
}