<*
 Reading logind into a `State`: this process's session (its properties, `LockedHint`,
 `IdleHint`), the session list, and the seat list. Every object path comes from logind; every
 value is copied into the snapshot's arena.

 Sources: the same org.freedesktop.login1 names as `logind.c3`; the property types are those
 the manual page gives (Id s, User (uo), Name s, Seat (so), Type s, Active b, Remote b,
 LockedHint b, IdleHint b).
*>
module bleu::session::logind @feat(LINUX);
import std::collections::list, std::collections::maybe, bleu::dbus::marshal, bleu::dbus::message, bleu::dbus::proxy, bleu::dbus::value, bleu::error, bleu::session;

<* A string property of a session, copied into `allocator`; "" when absent or not a string. *>
fn String prop_text(Value props, String name, Allocator allocator)
{
	if (try v = props.dict_get(name))
	{
		if (try text = v.as_string()) return text.copy(allocator);
	}
	return "";
}

<* A boolean property, empty when absent. *>
fn Maybe{bool} prop_bool(Value props, String name)
{
	if (try v = props.dict_get(name))
	{
		if (try flag = v.as_bool()) return maybe::value(flag);
	}
	return { };
}

<* The session fields of a `Session` property dictionary. Absent properties stay empty. *>
fn SessionInfo session_info(Value props, Allocator allocator)
{
	SessionInfo info = {
		.id = prop_text(props, "Id", allocator),
		.user = prop_text(props, "Name", allocator),
		.seat = seat_of(props, allocator),
		.type = session::session_type_of(prop_text(props, "Type", tmem)),
		.active = prop_bool(props, "Active"),
		.remote = prop_bool(props, "Remote"),
	};
	if (try user = props.dict_get("User"))
	{
		if (try uid = user.at(0))
		{
			if (try number = uid.as_u32()) info.uid = maybe::value(number);
		}
	}
	return info;
}

<* The seat id of the `Seat` property, a (so) pair; "" when the session has no seat. *>
fn String seat_of(Value props, Allocator allocator)
{
	if (try seat = props.dict_get("Seat"))
	{
		if (try id = seat.at(0))
		{
			if (try text = id.as_string()) return text.copy(allocator);
		}
	}
	return "";
}

<*
 Read the session of this process: its fields, `LockedHint` and `IdleHint`. Records the lock state for the next change.
*>
fn State? read_state(Logind* b, Allocator allocator)
{
	if (!b.connected) return error::UNAVAILABLE~;
	@pool()
	{
		State state = { .sleeping = b.sleeping };
		if (b.has_session)
		{
			Value props = b.session.get_all_properties(tmem)!;
			state.current = session_info(props, allocator);
			state.locked = prop_bool(props, "LockedHint");
			state.idle_hint = prop_bool(props, "IdleHint");
		}
		state.seats = read_seats(b, allocator)!;
		state.sessions = read_sessions(b, allocator)!;
		return state;
	};
}

<* The seat ids from `ListSeats` (a(so)). *>
fn String[]? read_seats(Logind* b, Allocator allocator)
{
	@pool()
	{
		Value seats  = call_list(b, "ListSeats", tmem)!;
		String[] ids = alloc::new_array(allocator, String, (sz)seats.count());
		for (usz i = 0; i < seats.count(); i++)
		{
			Value seat = seats.at(i)!;
			ids[i] = seat.at(0)!.as_string()!.copy(allocator);
		}
		return ids;
	};
}

<*
 The sessions from `ListSessions` (a(susso)). Each is read again by its object path, for its
 type and state. A session that ended after it was listed is skipped; a lost bus is an error.
*>
fn SessionInfo[]? read_sessions(Logind* b, Allocator allocator)
{
	@pool()
	{
		Value sessions = call_list(b, "ListSessions", tmem)!;
		List{SessionInfo} infos;
		infos.init(tmem);
		for (usz i = 0; i < sessions.count(); i++)
		{
			String path       = sessions.at(i)!.at(4)!.as_object_path()!;
			SessionInfo? info = read_session(b, path, allocator);
			if (catch err = info)
			{
				// A session that ended after it was listed is gone (UnknownObject, NOT_FOUND): skip it.
				// Any other failure fails the whole read, so no snapshot leaves a session out silently.
				if (err != NOT_FOUND) return err~;
			}
			else
			{
				infos.push(info);
			}
		}
		if (infos.is_empty()) return { };
		SessionInfo[] out = alloc::new_array(allocator, SessionInfo, infos.len());
		for (sz i = 0; i < infos.len(); i++) out[i] = infos.get(i);
		return out;
	};
}

<* One session by object path. */ *>
fn SessionInfo? read_session(Logind* b, String path, Allocator allocator)
{
	proxy::Proxy object = proxy::for_object(&b.bus, LOGIND_BUS, path, LOGIND_SESSION)!;
	Value props         = object.get_all_properties(tmem)!;
	return session_info(props, allocator);
}

<* A call on the Manager that takes no arguments and returns one value (`ListSeats`, `ListSessions`). *>
fn Value? call_list(Logind* b, String member, Allocator allocator)
{
	Message* call = b.manager.new_call(allocator, member)!;
	defer call.release();
	Message* reply = b.bus.call(call)!;
	defer reply.release();
	marshal::Reader body = reply.reader()!;
	return body.read_value(allocator);
}