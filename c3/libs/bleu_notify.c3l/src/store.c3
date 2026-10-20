<*
 The notification centre's bookkeeping, with no I/O and no bus: which
 notifications are open, which are history, what replaces what, what is evicted.

 Each notification is an `Entry` owning an arena for all of its text. Closing
 one frees its arena, so nothing is copied when it moves from the wire into the
 store. `state` deep-copies everything into a published snapshot.
*>
module bleu::notify::store;
import std::collections::list, std::collections::maybe, std::time, bleu::notify, bleu::notify::markup, bleu::notify::rules, bleu::notify::wire;

<* A notification the centre holds. Its text lives in `arena`, which is freed with it. *>
struct Entry
{
	Allocator parent;
	DynamicArenaAllocator arena;
	wire::Incoming incoming;
	notify::Notification note;
}

<* What `Store.post` did, for the backend to announce and to time. *>
struct Posted
{
	notify::NoteId id;
	bool replaced;             // an open notification with this id (or stack tag) was replaced
	bool shown;                // false: do-not-disturb recorded it in history only
	Maybe{Duration} timeout;   // when it expires, if it does
	bool evicted;              // another open notification was closed to make room
	notify::NoteId evicted_id;
}

<* The store of one notification centre. `active` is newest first; so is `history`. *>
struct Store
{
	Allocator allocator;
	notify::Policy policy;
	List{Entry*} active;
	List{Entry*} history;
	notify::NoteId last_id;
	uint received;
	bool dnd;
}

<* Prepare an empty store whose entries are allocated from `allocator`. *>
fn void Store.init(&self, Allocator allocator, notify::Policy policy)
{
	*self = { .allocator = allocator, .policy = policy };
	self.active.init(allocator);
	self.history.init(allocator);
}

<* Release every entry and the lists. *>
fn void Store.free(&self)
{
	while (try e = self.active.pop()) release_entry(e);
	while (try e = self.history.pop()) release_entry(e);
	self.active.free();
	self.history.free();
}

<* A new entry with an empty arena, for `wire::read_notify` to fill. *>
fn Entry* Store.new_entry(&self)
{
	Entry* e = alloc::new(self.allocator, Entry);
	e.parent = self.allocator;
	e.arena.init(self.allocator, 1024);
	return e;
}

<* Free an entry and its text. *>
fn void release_entry(Entry* e)
{
	Allocator allocator = e.parent;
	e.arena.free();
	alloc::free(allocator, e);
}

<*
 Take a decoded Notify call into the store. A replacement (by `replaces_id`, or
 by a stack tag that matches an open notification) keeps the old id and its
 place on screen; anything else gets the next id. Do-not-disturb holds back a
 new non-critical notification into history. When the open limit is reached,
 the oldest non-critical open notification is closed to make room.

 Takes ownership of `e`: it is in the store afterwards, or released.
*>
fn Posted Store.post(&self, Entry* e, Time now)
{
	Posted result;
	notify::Urgency urgency = e.incoming.hints.urgency;
	int index = self.find_active(e.incoming.replaces_id);
	if (e.incoming.replaces_id != 0) self.drop_from_history(e.incoming.replaces_id);
	if (index < 0 && e.incoming.hints.stack_tag.len > 0) index = self.find_stack(e.incoming.hints.stack_tag);
	notify::NoteId id;
	if (index >= 0)
	{
		id = self.active.get((sz)index).note.id;
	}
	else if (e.incoming.replaces_id != 0)
	{
		id = e.incoming.replaces_id;
	}
	else
	{
		id = rules::next_id(self.last_id);
		self.last_id = id;
	}
	bool shown = index >= 0 || !rules::held_by_dnd(self.dnd, urgency);
	if (shown && index < 0 && (usz)self.active.len() >= self.policy.max_open)
	{
		Entry* victim = self.take_eviction_victim();
		result.evicted = true;
		result.evicted_id = victim.note.id;
		self.retire(victim);
	}
	Maybe{Duration} timeout = shown ? rules::timeout_for(urgency, e.incoming.expire_ms, &self.policy) : { };
	fill_note(e, id, now, timeout);
	if (index >= 0)
	{
		Entry* old = self.active.get((sz)index);
		self.active.set_at((sz)index, e);
		release_entry(old);
	}
	else if (shown)
	{
		self.active.push_front(e);
	}
	else
	{
		self.retire(e);
	}
	self.received++;
	result.id = id;
	result.replaced = index >= 0;
	result.shown = shown;
	result.timeout = timeout;
	return result;
}

// Set the public record of `e` from what the wire carried. The body's runs are parsed into the entry's arena.
fn void fill_note(Entry* e, notify::NoteId id, Time now, Maybe{Duration} timeout)
{
	wire::Incoming* in = &e.incoming;
	Maybe{Time} expires = { };
	if (timeout.has_value) expires = maybe::value((Time)((long)now + (long)timeout.value));
	e.note = {
		.id = id,
		.created = now,
		.expires = expires,
		.urgency = in.hints.urgency,
		.app_name = in.app_name,
		.app_icon = in.app_icon,
		.desktop_entry = in.hints.desktop_entry,
		.category = in.hints.category,
		.summary = in.summary,
		.body = markup::parse(&e.arena, in.body),
		.actions = in.actions,
		.image_path = in.hints.image_path,
		.has_image = in.hints.has_image,
		.image = in.hints.image,
		.progress = in.hints.progress,
		.stack_tag = in.hints.stack_tag,
		.resident = in.hints.resident,
		.transient = in.hints.transient,
		.suppress_sound = in.hints.suppress_sound,
		.sound_name = in.hints.sound_name,
		.sound_file = in.hints.sound_file,
	};
}

<*
 Take the open notification `id` out of the centre and into history (or drop it,
 when it is transient). Returns false when no open notification has this id.
*>
fn bool Store.close(&self, notify::NoteId id)
{
	int index = self.find_active(id);
	if (index < 0) return false;
	Entry* e = self.active.get((sz)index);
	self.active.remove_at((sz)index);
	self.retire(e);
	return true;
}

<* The open notification with `id`, or null. It stays in the store. *>
fn Entry* Store.open(&self, notify::NoteId id)
{
	int index = self.find_active(id);
	return index < 0 ? null : self.active.get((sz)index);
}

<* Drop every history entry. *>
fn void Store.clear_history(&self)
{
	while (try e = self.history.pop()) release_entry(e);
}

// Put a closed notification at the front of history, keeping at most `history_limit`.
fn void Store.retire(&self, Entry* e)
{
	if (e.note.transient)
	{
		release_entry(e);
		return;
	}
	// The pixels are dropped now: history keeps the text and the fact that there was an image.
	e.note.image.pixels = { };
	self.history.push_front(e);
	while ((usz)self.history.len() > self.policy.history_limit)
	{
		release_entry(self.history.pop()!!);
	}
}

// Index of the open notification with `id` (zero matches nothing), or -1.
fn int Store.find_active(&self, notify::NoteId id)
{
	if (id == 0) return -1;
	foreach (i, e : self.active)
	{
		if (e.note.id == id) return (int)i;
	}
	return -1;
}

// Index of the open notification with stack tag `tag`, or -1.
fn int Store.find_stack(&self, String tag)
{
	foreach (i, e : self.active)
	{
		if (e.note.stack_tag == tag) return (int)i;
	}
	return -1;
}

// Forget a history entry that a replacement now takes over.
fn void Store.drop_from_history(&self, notify::NoteId id)
{
	foreach (i, e : self.history)
	{
		if (e.note.id != id) continue;
		self.history.remove_at(i);
		release_entry(e);
		return;
	}
}

// Remove and return the oldest open non-critical notification, or the oldest of all when every one is critical.
fn Entry* Store.take_eviction_victim(&self)
{
	for (sz i = self.active.len() - 1; i >= 0; i--)
	{
		if (self.active.get(i).note.urgency != notify::Urgency.CRITICAL) return self.take_at(i);
	}
	return self.take_at(self.active.len() - 1);
}

fn Entry* Store.take_at(&self, sz index)
{
	Entry* e = self.active.get(index);
	self.active.remove_at(index);
	return e;
}

<* Hold back (true) or show (false) new non-critical notifications. Open ones are not affected. *>
fn void Store.set_do_not_disturb(&self, bool on) @inline => self.dnd = on;

<*
 Build the published view of the centre in `allocator`: every open and every
 historic notification, deep-copied. `serving` is left for the caller.
*>
fn void Store.fill(&self, notify::State* state, Allocator allocator)
{
	state.do_not_disturb = self.dnd;
	state.count = self.received;
	state.active = clone_all(&self.active, allocator);
	state.history = clone_all(&self.history, allocator);
}

fn notify::Notification[] clone_all(List{Entry*}* entries, Allocator allocator)
{
	notify::Notification[] out = alloc::new_array(allocator, notify::Notification, entries.len());
	foreach (i, e : entries) out[i] = clone_note(&e.note, allocator);
	return out;
}

// A copy of `n` whose strings, runs, actions and pixels are allocated in `allocator`.
fn notify::Notification clone_note(notify::Notification* n, Allocator allocator)
{
	notify::Notification c = *n;
	c.app_name = n.app_name.copy(allocator);
	c.app_icon = n.app_icon.copy(allocator);
	c.desktop_entry = n.desktop_entry.copy(allocator);
	c.category = n.category.copy(allocator);
	c.summary = n.summary.copy(allocator);
	c.image_path = n.image_path.copy(allocator);
	c.stack_tag = n.stack_tag.copy(allocator);
	c.sound_name = n.sound_name.copy(allocator);
	c.sound_file = n.sound_file.copy(allocator);
	c.body = clone_spans(n.body, allocator);
	c.actions = clone_actions(n.actions, allocator);
	c.image.pixels = n.image.pixels.len == 0 ? { } : alloc::clone_slice(allocator, n.image.pixels);
	return c;
}

fn notify::Span[] clone_spans(notify::Span[] spans, Allocator allocator)
{
	notify::Span[] out = alloc::new_array(allocator, notify::Span, spans.len);
	foreach (i, span : spans)
	{
		out[i] = span;
		out[i].text = span.text.copy(allocator);
		out[i].link = span.link.copy(allocator);
	}
	return out;
}

fn notify::Action[] clone_actions(notify::Action[] actions, Allocator allocator)
{
	notify::Action[] out = alloc::new_array(allocator, notify::Action, actions.len);
	foreach (i, action : actions)
	{
		out[i].key = action.key.copy(allocator);
		out[i].label = action.label.copy(allocator);
	}
	return out;
}
