<*
 Choosing the active player, and which commands a player allows.

 The active player is the one a shell shows when it has to show one: a playing
 player beats a paused one, which beats a stopped one; among equals, the one
 whose status changed most recently wins. Ties beyond that keep the earlier
 index, so the choice is stable for a given state.
*>
module bleu::media;

<* Rank of a playback status for the active-player choice: higher is preferred. *>
fn int playback_rank(Playback status)
{
	switch (status)
	{
		case PLAYING: return 2;
		case PAUSED: return 1;
		case STOPPED: return 0;
	}
}

<*
 Index of the active player, or -1 for none.

 @param statuses : "Each player's status"
 @param since : "Monotonic time each player's status last changed; same length as `statuses`"
 @require statuses.len == since.len : "One time per status"
*>
fn sz select_active(Playback[] statuses, Duration[] since)
{
	sz best = -1;
	for (sz i = 0; i < statuses.len; i++)
	{
		if (best < 0 || outranks(statuses[i], since[i], statuses[best], since[best])) best = i;
	}
	return best;
}

fn bool outranks(Playback a, Duration a_since, Playback b, Duration b_since) @private
{
	int ra = playback_rank(a);
	int rb = playback_rank(b);
	if (ra != rb) return ra > rb;
	return a_since > b_since;
}

<*
 Whether a player's advertised controls allow `kind`. Raise and quit are the
 only commands that do not need the player to be controllable; the backend
 sets those flags from the player's own answers.
*>
fn bool Controls.allows(&self, CommandKind kind)
{
	switch (kind)
	{
		case PLAY: return self.play;
		case PAUSE: return self.pause;
		case PLAY_PAUSE: return self.play_pause;
		case STOP: return self.stop;
		case NEXT: return self.next;
		case PREVIOUS: return self.previous;
		case SEEK: return self.seek;
		case SET_POSITION: return self.set_position;
		case SET_RATE: return self.set_rate;
		case SET_VOLUME: return self.set_volume;
		case SET_SHUFFLE: return self.set_shuffle;
		case SET_LOOP: return self.set_loop;
		case RAISE: return self.raise;
		case QUIT: return self.quit;
		case REFRESH: return true;
	}
}

<* The service-level capability a command needs. `REFRESH` needs only observation. *>
fn Cap cap_of(CommandKind kind)
{
	switch (kind)
	{
		case PLAY:
		case PAUSE:
		case PLAY_PAUSE:
		case STOP:
		case NEXT:
		case PREVIOUS: return TRANSPORT;
		case SEEK:
		case SET_POSITION: return SEEK;
		case SET_RATE: return RATE;
		case SET_VOLUME: return VOLUME;
		case SET_SHUFFLE: return SHUFFLE;
		case SET_LOOP: return LOOP;
		case RAISE: return RAISE;
		case QUIT: return QUIT;
		case REFRESH: return OBSERVE;
	}
}
