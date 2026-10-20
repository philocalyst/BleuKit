<*
 Carrying out commands on the worker: each one becomes one D-Bus call, and its
 operation completes when the reply arrives.

 A command is checked against the player's own answers (`Controls`) before the
 player is asked, so a refused control fails with `error::UNSUPPORTED` without
 a round trip. A `SetPosition` names the track the caller saw; when the player
 has a track id and it is not the current one, the call is refused with
 `error::INVALID_STATE` instead of being sent. Sending it would be safe only
 if the player checked the id, and the Backend.MPRIS spec says it should, but the
 refusal is visible to the caller and does not depend on that.

 Players with no track id (`mpris:trackid` absent or "/") cannot be asked for
 an absolute position safely, so the target is sent as a relative `Seek` from
 the position the service last anchored (Backend.MPRIS 2.2 `Seek`).
*>
module bleu::media::mpris @feat(LINUX);
import std::time, bleu::dbus::marshal, bleu::dbus::message, bleu::dbus::proxy, bleu::dbus::value, bleu::error, bleu::media, bleu::operation;

<* Carry out `c` and complete its operation, if it has one. *>
fn void Session.execute(&self, Command* c)
{
	CommandOp* op = c.op;
	if (catch err = self.perform(c))
	{
		self.absorb(err);
		if (op != null)
		{
			op.fail(err);
			op.release();
		}
		return;
	}
	if (op != null)
	{
		op.succeed(true);
		op.release();
	}
}

// Dispatch on the command kind. Refresh needs no player; everything else does.
fn void? Session.perform(&self, Command* c)
{
	if (c.kind == CommandKind.REFRESH)
	{
		self.refresh_all();
		return;
	}
	Record* r = self.find(c.player);
	if (r == null) return NOT_FOUND~;
	if (!r.controls.allows(c.kind)) return error::UNSUPPORTED~;
	@pool()
	{
		switch (c.kind)
		{
			case CommandKind.PLAY: return self.call_member(&r.player, "Play");
			case CommandKind.PAUSE: return self.call_member(&r.player, "Pause");
			case CommandKind.PLAY_PAUSE: return self.call_member(&r.player, "PlayPause");
			case CommandKind.STOP: return self.call_member(&r.player, "Stop");
			case CommandKind.NEXT: return self.call_member(&r.player, "Next");
			case CommandKind.PREVIOUS: return self.call_member(&r.player, "Previous");
			case CommandKind.SEEK: return self.call_offset(&r.player, c.amount);
			case CommandKind.SET_POSITION: return self.set_position(r, c);
			case CommandKind.SET_RATE: return self.set_player_property(r, "Rate", value::float64((double)(float)c.rate));
			case CommandKind.SET_VOLUME: return self.set_player_property(r, "Volume", value::float64((double)(float)c.volume));
			case CommandKind.SET_SHUFFLE: return self.set_player_property(r, "Shuffle", value::boolean(c.flag));
			case CommandKind.SET_LOOP: return self.set_loop(r, c.loop);
			case CommandKind.RAISE: return self.call_member(&r.root, "Raise");
			case CommandKind.QUIT: return self.call_member(&r.root, "Quit");
			case CommandKind.REFRESH: return;
		}
	};
}

// A method with no arguments on `proxy`.
fn void? Session.call_member(&self, Proxy* proxy, String member)
{
	Message* call = proxy.new_call(self.allocator, member)!;
	defer call.release();
	self.send(call)!;
}

// `Seek(x)`: a relative move in microseconds.
fn void? Session.call_offset(&self, Proxy* proxy, Duration offset)
{
	Message* call = proxy.new_call(self.allocator, "Seek")!;
	defer call.release();
	call.body_writer("x")!.append_i64((long)offset)!;
	self.send(call)!;
}

// `SetPosition(o, x)`, or the relative seek that replaces it on a track with no id.
fn void? Session.set_position(&self, Record* r, Command* c)
{
	if (r.track.id.len == 0)
	{
		if (!r.position.has_value)
		{
			return error::raise(
				error::UNAVAILABLE,
				error::Domain.INTERNAL,
				0,
				"the player has not reported a position"
			)~;
		}
		Duration now = media::monotonic_now();
		Duration at  = media::position_at(r.position.value, r.status, r.rate, r.track.length, now);
		return self.call_offset(&r.player, c.amount - at);
	}
	if (c.track_id() != r.track.id)
	{
		return error::raise(
			error::INVALID_STATE,
			error::Domain.INTERNAL,
			0,
			"the track changed before the request arrived"
		)~;
	}
	Message* call = r.player.new_call(self.allocator, "SetPosition")!;
	defer call.release();
	Writer* body = call.body_writer("ox")!;
	body.append_object_path(r.track.id)!;
	body.append_i64((long)c.amount)!;
	self.send(call)!;
}

// `Set` on the Player interface with a value the caller built.
fn void? Session.set_player_property(&self, Record* r, String name, Value v)
{
	r.player.set_property(name, v, CALL_TIMEOUT)!;
	self.busy = true;
}

// `LoopStatus`, which is text on the wire.
fn void? Session.set_loop(&self, Record* r, Loop loop)
{
	Value v = value::str(tmem, mpris_convert::loop_text(loop))!;
	r.player.set_property("LoopStatus", v, CALL_TIMEOUT)!;
	self.busy = true;
}