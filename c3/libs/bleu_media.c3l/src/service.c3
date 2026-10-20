<*
 The media service: read the players, wait for changes, control them.

 Media* media = media::open(mem, { .backend = AUTO })!;
 defer media.close();
 if (try snapshot = media.latest())
 {
 defer snapshot.release();
 // snapshot.value.players ...
 }
 Operation{bool}* done = media.play(player.handle)!;
 defer done.release();
 done.wait(time::sec(2))!;

 Every method may be called from any thread. Commands return at once with an
 `Operation`; the player's own change arrives later through the observable
 (see `Operation` in `bleu::operation`). An operation completes with `true`
 when the player's reply arrived without error. Calls that are refused before
 they reach the worker (a capability this platform lacks, a full queue) return
 the fault directly.
*>
module bleu::media;
import std::collections::enummap, std::time, bleu::error, bleu::availability, bleu::observe, bleu::stream, bleu::service, bleu::operation, bleu::unit;

alias MediaHub = Hub{State, Command, Event};
alias Capabilities = EnumMap{Cap, Availability};
alias CommandOp = Operation{bool};

const Duration DEFAULT_REFRESH = time::SEC;

struct Media
{
	Allocator allocator;
	MediaHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
}

<*
 Open the first working backend of this platform (or the one in `options`).

 @param allocator : "Allocator for the service and its snapshots"
 @return? error::UNAVAILABLE : "No backend works here (no player bus, no media session service)"
 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
*>
fn Media*? open(Allocator allocator, Options options = { })
{
	if (options.refresh == time::DURATION_ZERO) options.refresh = DEFAULT_REFRESH;
	Driver* driver = select_driver(options)!;
	Capabilities capabilities;
	void* state = driver.create(allocator, options, &capabilities)!;
	Media* self = alloc::new(allocator, Media);
	*self = { .allocator = allocator, .driver = driver, .driver_state = state, .capabilities = capabilities };
	if (catch err = self.hub.start(allocator, "media", driver.info.name, driver.run, state))
	{
		driver.destroy(allocator, state);
		alloc::free(allocator, self);
		return err~;
	}
	return self;
}

<* Stop the backend and release everything. Outstanding operations still complete. *>
fn void Media.close(&self)
{
	self.hub.stop();
	self.driver.destroy(self.allocator, self.driver_state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend in use, for diagnostics ("mpris", "smtc", "scripting"). *>
fn String Media.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Media.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The backend has not produced its first reading yet"
*>
fn Snapshot{State}*? Media.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`, then pass
 the previous snapshot's `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn Snapshot{State}*? Media.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later state. Quick and non-blocking only. *>
fn WatchId{State} Media.watch(&self, Listener{State} listener, void* context) => self.hub.state.watch(listener, context);

<* Remove a listener; when this returns it is not running. Not from inside a listener. *>
fn void Media.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<* Subscribe to transient events: players added, removed, status, track, seeks, active player. *>
fn Reader{Event}*? Media.subscribe(&self) => self.hub.events.subscribe();

<*
 Ask the backend to read the players now; returns once the request is queued.
 Players are read on every change already, so this is for diagnostics.
*>
fn void? Media.refresh(&self) => self.hub.post(command(REFRESH, 0));

<* Start or resume playback of `player`. *>
fn CommandOp*? Media.play(&self, ulong player) => submit(self, command(PLAY, player));

<* Pause `player`. *>
fn CommandOp*? Media.pause(&self, ulong player) => submit(self, command(PAUSE, player));

<* Pause when playing and play when paused. *>
fn CommandOp*? Media.play_pause(&self, ulong player) => submit(self, command(PLAY_PAUSE, player));

<* Stop `player`; a later play starts from the beginning. *>
fn CommandOp*? Media.stop(&self, ulong player) => submit(self, command(STOP, player));

<* Skip to the next track. *>
fn CommandOp*? Media.next(&self, ulong player) => submit(self, command(NEXT, player));

<* Go to the previous track. *>
fn CommandOp*? Media.previous(&self, ulong player) => submit(self, command(PREVIOUS, player));

<*
 Move `offset` relative to the current position; negative moves back.

 @param offset : "Microseconds"
*>
fn CommandOp*? Media.seek(&self, ulong player, Duration offset)
{
	Command c = command(SEEK, player);
	c.amount = offset;
	return submit(self, c);
}

<*
 Move to an absolute position in the track `track_id`. The player ignores the
 request if the track has changed; the service instead refuses it with
 `error::INVALID_STATE` when it can see that the track changed first.

 @param track_id : "The `Track.id` the caller saw; \"\" when the player had none"
 @param position : "Microseconds from the start of the track"
 @return? error::INVALID_ARGUMENT : "The track id is longer than TRACK_ID_CAPACITY"
*>
fn CommandOp*? Media.set_position(&self, ulong player, String track_id, Duration position)
{
	if (track_id.len > TRACK_ID_CAPACITY) return error::INVALID_ARGUMENT~;
	Command c = command(SET_POSITION, player);
	c.amount = position;
	mem::copy(&c.track, track_id.ptr, track_id.len);
	c.track_len = track_id.len;
	return submit(self, c);
}

<* Set the playback speed; 1.0 is normal. *>
fn CommandOp*? Media.set_rate(&self, ulong player, PlaybackRate rate)
{
	Command c = command(SET_RATE, player);
	c.rate = rate;
	return submit(self, c);
}

<* Set the player's volume, where 1.0 is its nominal full volume. *>
fn CommandOp*? Media.set_volume(&self, ulong player, Level volume)
{
	Command c = command(SET_VOLUME, player);
	c.volume = volume;
	return submit(self, c);
}

<* Turn shuffle on or off. *>
fn CommandOp*? Media.set_shuffle(&self, ulong player, bool on)
{
	Command c = command(SET_SHUFFLE, player);
	c.flag = on;
	return submit(self, c);
}

<* Set the repeat mode. *>
fn CommandOp*? Media.set_loop(&self, ulong player, Loop loop)
{
	Command c = command(SET_LOOP, player);
	c.loop = loop;
	return submit(self, c);
}

<* Bring the player's window forward. *>
fn CommandOp*? Media.raise(&self, ulong player) => submit(self, command(RAISE, player));

<* Ask the player to exit. *>
fn CommandOp*? Media.quit(&self, ulong player) => submit(self, command(QUIT, player));

fn Command command(CommandKind kind, ulong player) @inline => { .kind = kind, .player = player };

// Check the capability, retain the operation for the worker, and queue the command.
fn CommandOp*? submit(Media* media, Command c) @private
{
	Availability availability = media.capabilities.values[cap_of(c.kind).ordinal];
	if (!availability.ok()) return availability.refusal()~;
	CommandOp* op = operation::begin(media.allocator);
	c.op = op.retain();
	if (catch err = media.hub.post(c))
	{
		op.release(); // the worker's reference, which will never be used
		op.release(); // the caller's, which is not returned
		return err~;
	}
	return op;
}
