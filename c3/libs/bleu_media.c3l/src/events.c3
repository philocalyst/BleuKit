<*
 Turning two states into the events that describe the change between them.

 Pure: the backend publishes a state, then asks this for the events and emits
 them. Players are matched by `handle`, so a player that vanished and came back
 under the same bus name is a removal and an addition.
*>
module bleu::media;
import std::collections::list;

<*
 Append the events that turn `before` into `after` to `out`.

 @param seeked : "Handles of players that reported a seek since `before`"
 @param out : "Receives the events, in player order; allocated in its own allocator"
*>
fn void collect_events(State* before, State* after, ulong[] seeked, List{Event}* out)
{
	ulong active_before = active_handle(before);
	ulong active_after  = active_handle(after);
	foreach (&now : after.players)
	{
		Player* was = find(before, now.handle);
		if (was == null)
		{
			out.push({ .kind = PLAYER_ADDED, .player = now.handle, .id = now.id });
			continue;
		}
		if (was.status != now.status) out.push({ .kind = STATUS_CHANGED, .player = now.handle, .id = now.id });
		if (was.track.id != now.track.id || was.track.title != now.track.title)
		{
			out.push({ .kind = TRACK_CHANGED, .player = now.handle, .id = now.id });
		}
		if (contains(seeked, now.handle)) out.push({ .kind = SEEKED, .player = now.handle, .id = now.id });
	}
	foreach (&was : before.players)
	{
		if (find(after, was.handle) == null) out.push({ .kind = PLAYER_REMOVED, .player = was.handle, .id = was.id });
	}
	if (active_before != active_after)
	{
		out.push({ .kind = ACTIVE_CHANGED, .player = active_after, .id = "" });
	}
}

// The handle of the active player, or 0 for none (handles start at 1).
fn ulong active_handle(State* state) @private
{
	foreach (&p : state.players)
	{
		if (p.is_active) return p.handle;
	}
	return 0;
}

fn Player* find(State* state, ulong handle) @private
{
	foreach (&p : state.players)
	{
		if (p.handle == handle) return p;
	}
	return null;
}

fn bool contains(ulong[] values, ulong value) @private
{
	foreach (v : values)
	{
		if (v == value) return true;
	}
	return false;
}