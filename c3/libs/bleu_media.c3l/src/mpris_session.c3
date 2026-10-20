<*
 The D-Bus side of the MPRIS backend: which players are on the bus, what each
 one says, and when to read again.

 Discovery: `ListNames` at start, then `NameOwnerChanged` for every name with
 the MPRIS prefix. Each player gets `PropertiesChanged` on its Player interface
 and `Seeked` (MPRIS 2.2, "Seeked"). `Position` is never signalled, so every
 read anchors it and `tick` re-anchors the playing players once per refresh
 interval (see `position.c3`).

 Signal handlers run inside `Connection.process`, so they only set flags; the
 bus calls they imply are made by the loop afterwards. Records are freed only
 outside `process`, so the pointers the subscriptions carry stay valid.
*>
module bleu::media::mpris @feat(LINUX);
import std::collections::list, std::collections::maybe, std::time, bleu::dbus::bus, bleu::dbus::connection, bleu::dbus::marshal, bleu::dbus::match, bleu::dbus::message, bleu::dbus::proxy, bleu::dbus::value, bleu::error, bleu::media, bleu::media::mpris_convert, bleu::observe, bleu::rt::poller, bleu::stream, bleu::unit;

<* Longest wait for one D-Bus call. A player that does not answer in this time is skipped for the round. *>
const Duration CALL_TIMEOUT = (Duration)2_000_000;

<* Page size of each record's arena. Pages grow on demand. *>
const sz RECORD_ARENA_PAGE = 1024;

<* The signal a player sends when its position jumped (MPRIS 2.2, "Seeked"). *>
const String SEEKED_MEMBER = "Seeked";

<* One player on the bus: its proxies, its subscriptions, and what was last read from it. *>
struct Record
{
	ulong handle;
	String name; // the bus name, from the session allocator; the proxies point at it
	Proxy root;
	Proxy player;
	SubscriptionId properties_watch; // 0 when not subscribed
	SubscriptionId seek_watch;       // 0 when not subscribed
	DynamicArenaAllocator arena;     // every string below; reset on each full read
	String identity;
	String desktop_entry;
	Playback status;
	Duration status_since;           // monotonic time the status last changed
	Track track;
	Controls controls;
	Maybe{Anchor} position;
	PlaybackRate rate;
	Maybe{Level} volume;
	Maybe{bool} shuffle;
	Maybe{Loop} loop;
	bool dirty;        // a PropertiesChanged arrived: read everything again
	bool seek_pending; // a Seeked arrived: the next publication reports it
}

<* The players of one bus connection. Lives on the worker thread that opened it. *>
struct Session
{
	Allocator allocator;
	Connection connection;
	List{Record*} records;
	ulong next_handle;
	SubscriptionId owner_watch;
	Duration refresh;
	Duration next_tick;  // monotonic time of the next position re-read
	bool roster_dirty;   // an MPRIS name appeared or vanished: list the bus again
	bool disconnected;   // the bus went away; the loop stops
	bool busy;           // calls were made: wait without blocking once, so queued messages are dispatched
}

<* Open a bus connection: the address given, or the session bus. *>
fn void? open_bus(Connection* c, String address)
{
	if (address.len > 0) return c.open_address(address);
	return c.open_session();
}

<*
 Connect and watch for players appearing and vanishing. Must run on the thread
 that will use the session, since a connection belongs to its thread.
*>
fn void? Session.open(&self, Allocator allocator, String address, Duration refresh)
{
	self.allocator = allocator;
	self.refresh = refresh;
	self.next_handle = 1;
	self.records.init(allocator);
	self.connection.init(allocator);
	if (catch err = open_bus(&self.connection, address))
	{
		self.connection.free();
		self.records.free();
		return err~;
	}
	if (catch err = self.watch_owners())
	{
		self.connection.free();
		self.records.free();
		return err~;
	}
}

// Every NameOwnerChanged on the bus; the handler keeps only the MPRIS names.
fn void? Session.watch_owners(&self)
{
	match::Match rule;
	rule.init(self.allocator);
	rule.with_type(MessageType.SIGNAL)!!;
	rule.with_sender(connection::BUS_NAME)!!;
	rule.with_interface(connection::BUS_INTERFACE)!!;
	rule.with_member(bus::NAME_OWNER_CHANGED)!!;
	self.owner_watch = self.connection.subscribe(rule, &on_owner_change, self)!;
}

<* Drop every player and close the connection. The session must not be used afterwards. *>
fn void Session.close(&self)
{
	self.forget_all();
	if (self.owner_watch != 0)
	{
		// The bus may be gone already; then there is no rule left to remove.
		if (catch err = self.connection.unsubscribe(self.owner_watch)) {}
	}
	self.connection.free();
	self.records.free();
}

<* Remove every player record. *>
fn void Session.forget_all(&self)
{
	while (self.records.size > 0) self.remove(self.records.array_view()[0]);
}

<* Record the failure of one player's call, or of the bus. Only a lost bus stops the service. *>
fn void Session.absorb(&self, fault err)
{
	if (err == error::DISCONNECTED) self.disconnected = true;
}

// Handler for NameOwnerChanged: flags the roster, and the record of a name whose owner changed.
fn void on_owner_change(void* context, Message* signal) @private
{
	Session* s = (Session*)context;
	String name;
	String old_owner;
	String new_owner;
	if (catch bus::name_owner_change(signal, &name, &old_owner, &new_owner)) return;
	if (!mpris_convert::is_player_name(name)) return;
	s.roster_dirty = true;
	Record* r = s.find_name(name);
	if (r != null) r.dirty = true;
}

// Handler for PropertiesChanged on a player's Player interface.
fn void on_properties(void* context, PropertyChange* change) @private
{
	Record* r = (Record*)context;
	r.dirty = true;
}

// Handler for Seeked: the position jumped, so the anchor is stale.
fn void on_seeked(void* context, Message* signal) @private
{
	Record* r = (Record*)context;
	r.seek_pending = true;
	r.dirty = true;
}

<* The record for bus name `name`, or null. *>
fn Record* Session.find_name(&self, String name)
{
	foreach (r : self.records.array_view())
	{
		if (r.name == name) return r;
	}
	return null;
}

<* The record with `handle`, or null. *>
fn Record* Session.find(&self, ulong handle)
{
	foreach (r : self.records.array_view())
	{
		if (r.handle == handle) return r;
	}
	return null;
}

<*
 List the bus names and make the records match: players that appeared are
 added and read; players whose name vanished are removed.
*>
fn void? Session.reconcile(&self)
{
	self.roster_dirty = false;
	@pool()
	{
		String[] names = self.connection.list_names(tmem)!;
		List{Record*} gone;
		gone.init(tmem);
		foreach (r : self.records.array_view())
		{
			if (!contains_name(names, r.name)) gone.push(r);
		}
		foreach (r : gone.array_view()) self.remove(r);
		foreach (name : names)
		{
			if (!mpris_convert::is_player_name(name) || self.find_name(name) != null) continue;
			if (catch err = self.add(name))
			{
				self.absorb(err);
				if (self.disconnected) return err~;
			}
		}
	};
}

fn bool contains_name(String[] names, String name) @private
{
	foreach (n : names)
	{
		if (n == name) return true;
	}
	return false;
}

<* Start watching the player on `name`, then read it. *>
fn void? Session.add(&self, String name)
{
	Record* r = alloc::new(self.allocator, Record, { .handle = self.next_handle++, .name = name.copy(self.allocator) });
	r.arena.init(self.allocator, RECORD_ARENA_PAGE);
	self.records.push(r);
	if (catch err = self.watch(r))
	{
		self.remove(r);
		return err~;
	}
	if (catch err = self.read(r)) self.absorb(err);
}

// Build the proxies and subscribe to the player's properties and seeks.
fn void? Session.watch(&self, Record* r)
{
	r.root = proxy::for_object(&self.connection, r.name, mpris_convert::OBJECT_PATH, mpris_convert::ROOT_INTERFACE)!;
	r.player = proxy::for_object(&self.connection, r.name, mpris_convert::OBJECT_PATH, mpris_convert::PLAYER_INTERFACE)!;
	r.properties_watch = r.player.watch_properties(&on_properties, r)!;
	match::Match rule;
	rule.init(self.allocator);
	rule.with_type(MessageType.SIGNAL)!!;
	rule.with_sender(r.name)!;
	rule.with_path(mpris_convert::OBJECT_PATH)!!;
	rule.with_interface(mpris_convert::PLAYER_INTERFACE)!!;
	rule.with_member(SEEKED_MEMBER)!!;
	r.seek_watch = self.connection.subscribe(rule, &on_seeked, r)!;
}

<* Stop watching a record and free it. *>
fn void Session.remove(&self, Record* r)
{
	for (sz i = 0; i < self.records.size; i++)
	{
		if (self.records.array_view()[i] == r)
		{
			self.records.remove_at(i);
			break;
		}
	}
	// A bus that is gone has no rules left to remove; the error says so and changes nothing.
	if (r.properties_watch != 0)
	{
		if (catch err = self.connection.unsubscribe(r.properties_watch)) {}
	}
	if (r.seek_watch != 0)
	{
		if (catch err = self.connection.unsubscribe(r.seek_watch)) {}
	}
	r.arena.free();
	alloc::free(self.allocator, r.name.ptr);
	alloc::free(self.allocator, r);
}

<*
 Read everything about the player: identity, controls, status, rate, volume,
 shuffle, loop, track and position. The replies are read into temporaries
 first, so a failed read leaves the last good record in place.
*>
fn void? Session.read(&self, Record* r)
{
	@pool()
	{
		Value root   = r.root.get_all_properties(tmem, CALL_TIMEOUT)!;
		Value player = r.player.get_all_properties(tmem, CALL_TIMEOUT)!;
		Maybe{Anchor} position = {};
		if (try anchor = self.read_position(r)) position = maybe::value(anchor);
		Duration now = monotonic_now();
		r.arena.reset();
		Allocator a = &r.arena;
		r.identity = copy_text(text_of(root, "Identity"), a);
		r.desktop_entry = copy_text(text_of(root, "DesktopEntry"), a);
		r.controls = controls_of(player, root);
		PlaybackRate rate = rate_of(double_of(player, "Rate"));
		Playback status = effective_status(playback_of(text_of(player, "PlaybackStatus")), rate);
		if (r.status_since == time::DURATION_ZERO || status != r.status) r.status_since = now;
		r.status = status;
		r.rate = rate;
		r.volume = volume_of(double_of(player, "Volume"));
		r.shuffle = flag_maybe(player, "Shuffle");
		r.loop = loop_maybe(player);
		r.track = {};
		if (try metadata = player.dict_get("Metadata")) r.track = mpris_convert::track_of(metadata, a);
		r.position = position;
	};
}

// Maybe-valued boolean property, empty when the player does not have it.
fn Maybe{bool} flag_maybe(Value dict, String key) @private
{
	if (try v = dict.dict_get(key))
	{
		if (try b = v.as_bool()) return maybe::value(b);
	}
	return {};
}

// Maybe-valued loop mode from `LoopStatus`, empty when the player does not have it.
fn Maybe{Loop} loop_maybe(Value player) @private
{
	if (try v = player.dict_get("LoopStatus"))
	{
		if (try s = v.as_string()) return maybe::value(loop_of(s));
	}
	return {};
}

<*
 Read the position only, and stamp it. The stamp is taken after the reply
 arrives, so the anchor is the time the player was at that position or later.
*>
fn Anchor? Session.read_position(&self, Record* r)
{
	self.busy = true;
	@pool()
	{
		Value v = r.player.get_property("Position", tmem, CALL_TIMEOUT)!;
		long us = v.as_i64()!;
		return { .position = (Duration)us, .taken_at = monotonic_now() };
	};
}

<* Re-read the position of every playing player once per refresh interval, to bound drift. *>
fn void Session.tick(&self)
{
	Duration now = monotonic_now();
	if (now < self.next_tick) return;
	self.next_tick = now + self.refresh;
	foreach (r : self.records.array_view())
	{
		if (r.status != PLAYING || r.dirty) continue;
		if (try anchor = self.read_position(r)) r.position = maybe::value(anchor);
	}
}

<* Read every record that a signal flagged. *>
fn void Session.refresh_dirty(&self)
{
	foreach (r : self.records.array_view())
	{
		if (!r.dirty) continue;
		r.dirty = false;
		self.busy = true;
		if (catch err = self.read(r)) self.absorb(err);
	}
}

<* Flag every player for a full read. *>
fn void Session.refresh_all(&self)
{
	foreach (r : self.records.array_view()) r.dirty = true;
}

<*
 How long the loop may sleep: not at all after calls, until the next position
 tick while something plays, and otherwise until something happens.
*>
fn Duration Session.wait_time(&self)
{
	if (self.busy) return time::DURATION_ZERO;
	foreach (r : self.records.array_view())
	{
		if (r.status != PLAYING) continue;
		Duration now = monotonic_now();
		return self.next_tick > now ? self.next_tick - now : time::DURATION_ZERO;
	}
	return time::FOREVER;
}

<* Clear the seek flags once the state that reports them is published. *>
fn void Session.clear_seeks(&self)
{
	foreach (r : self.records.array_view()) r.seek_pending = false;
}

<* Send a call on `call`, wait for the reply and drop it. The call itself is the caller's. *>
fn void? Session.send(&self, Message* call)
{
	self.busy = true;
	Message* reply = self.connection.call(call, CALL_TIMEOUT)!;
	reply.release();
}

<* Build the state as the records are now: sorted by id, copied into `allocator`, with the active player chosen. *>
fn State Session.build(&self, Allocator allocator)
{
	usz count = self.records.size;
	if (count == 0) return {};
	@pool()
	{
		Record*[] sorted = alloc::new_array(tmem, Record*, (sz)count);
		Record*[] live = self.records.array_view();
		for (usz i = 0; i < count; i++) sorted[i] = live[i];
		sort_by_name(sorted);
		Player[] players = alloc::new_array(allocator, Player, (sz)count);
		Playback[] statuses = alloc::new_array(tmem, Playback, (sz)count);
		Duration[] since = alloc::new_array(tmem, Duration, (sz)count);
		for (usz i = 0; i < count; i++)
		{
			players[i] = player_of(sorted[i], allocator);
			statuses[i] = sorted[i].status;
			since[i] = sorted[i].status_since;
		}
		sz active = select_active(statuses, since);
		if (active >= 0) players[active].is_active = true;
		return { .players = players };
	};
}

// Insertion sort: a handful of players.
fn void sort_by_name(Record*[] records) @private
{
	for (sz i = 1; i < records.len; i++)
	{
		Record* key = records[i];
		sz j = i - 1;
		while (j >= 0 && records[j].name.compare_to(key.name) > 0)
		{
			records[j + 1] = records[j];
			j--;
		}
		records[j + 1] = key;
	}
}

// The model's view of one record, with its strings copied into `allocator`.
fn Player player_of(Record* r, Allocator allocator) @private
{
	return {
		.handle = r.handle,
		.id = r.name.copy(allocator),
		.identity = copy_text(r.identity, allocator),
		.desktop_entry = copy_text(r.desktop_entry, allocator),
		.status = r.status,
		.track = mpris_convert::copy_track(&r.track, allocator),
		.position = r.position,
		.rate = r.rate,
		.volume = r.volume,
		.shuffle = r.shuffle,
		.loop = r.loop,
		.controls = r.controls,
	};
}

<*
 Publish the state if it differs from the last one, and emit the events of the
 change. A state that did not change publishes nothing and emits nothing.
*>
fn void Session.publish(&self, MediaHub* hub)
{
	Snapshot{State}* snapshot = hub.begin();
	snapshot.value = self.build(snapshot.allocator());
	Snapshot{State}* before = null;
	if (try latest = hub.latest()) before = latest;
	bool changed = hub.publish_if_changed(snapshot);
	if (changed) self.emit(hub, before);
	self.clear_seeks();
	if (before != null) before.release();
}

// Emit the events between `before` (null: nothing) and the state just published.
fn void Session.emit(&self, MediaHub* hub, Snapshot{State}* before)
{
	@pool()
	{
		State none = {};
		State* previous = before != null ? &before.value : &none;
		Snapshot{State}* after = hub.latest()!!;
		defer after.release();
		List{ulong} seeks;
		seeks.init(tmem);
		foreach (r : self.records.array_view())
		{
			if (r.seek_pending) seeks.push(r.handle);
		}
		List{Event} events;
		events.init(tmem);
		collect_events(previous, &after.value, seeks.array_view(), &events);
		foreach (e : events.array_view())
		{
			Packet{Event}* packet = hub.emit_begin();
			packet.value = { .kind = e.kind, .player = e.player, .id = copy_text(e.id, packet.allocator()) };
			hub.emit(packet);
		}
	};
}
