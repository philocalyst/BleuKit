<*
 Reading the logind and power-profiles-daemon properties into a `State`, and
 turning changes of the lid and external power into events.

 A failed read leaves the fields it feeds empty: "unknown", never a guessed
 value. Only a lost connection is remembered (`note_failure`).
*>
module bleu::power::logind @feat(LINUX);
import std::collections::list, std::collections::maybe, bleu::dbus::value, bleu::power, bleu::power::convert,
	bleu::observe;

<* Re-read every property this mechanism reports and publish the result if it changed. *>
fn void refresh(Logind* b)
{
	Snapshot{State}* snapshot = b.hub.begin();
	State* state = &snapshot.value;
	if (catch err = read_profiles(b, state, snapshot.allocator())) b.note_failure(err);
	if (catch err = read_manager(b, state)) b.note_failure(err);
	// Copy the readings out before publishing: publishing consumes the snapshot.
	Maybe{bool} lid = state.lid_closed;
	Maybe{bool} external = state.on_external_power;
	b.hub.publish_if_changed(snapshot);
	emit_transitions(b, lid, external);
}

// The profile, the profile list and the degradation reason, from power-profiles-daemon.
fn void? read_profiles(Logind* b, State* state, Allocator allocator)
{
	if (!b.has_profiles) return;
	@pool()
	{
		Value props = b.profiles.get_all_properties(tmem)!;
		if (try v = props.dict_get("ActiveProfile"))
		{
			if (try text = v.as_string())
			{
				if (try profile = convert::profile_from_name(text)) state.active_profile.set(profile);
			}
		}
		if (try v = props.dict_get("PerformanceDegraded"))
		{
			if (try text = v.as_string()) state.degraded = convert::degraded_from_text(text);
		}
		if (try entries = props.dict_get("Profiles"))
		{
			List{Profile} found;
			found.init(tmem);
			for (usz i = 0; i < entries.count(); i++)
			{
				if (try entry = entries.at(i))
				{
					if (try name = entry.dict_get("Profile"))
					{
						if (try text = name.as_string())
						{
							// Names this library does not know are left out, not guessed at.
							if (try profile = convert::profile_from_name(text)) found.push(profile);
						}
					}
				}
			}
			state.profiles = alloc::clone_slice(allocator, found.array_view());
		}
	};
}

// The lid, external power and idle hint, from logind's Manager properties.
fn void? read_manager(Logind* b, State* state)
{
	@pool()
	{
		Value props = b.manager.get_all_properties(tmem)!;
		if (try v = props.dict_get("LidClosed"))
		{
			if (try flag = v.as_bool()) state.lid_closed.set(flag);
		}
		if (try v = props.dict_get("OnExternalPower"))
		{
			if (try flag = v.as_bool()) state.on_external_power.set(flag);
		}
		if (try v = props.dict_get("IdleHint"))
		{
			if (try flag = v.as_bool()) state.idle_hint.set(flag);
		}
	};
}

// Emit an event for each change of a reading that was known before. The first reading sets the baseline only.
fn void emit_transitions(Logind* b, Maybe{bool} lid, Maybe{bool} external)
{
	if (lid.has_value)
	{
		if (b.last_lid.has_value && b.last_lid.value != lid.value)
		{
			power::publish_event(b.hub, lid.value ? LID_CLOSED : LID_OPENED, 0);
		}
		b.last_lid = lid;
	}
	if (external.has_value)
	{
		if (b.last_external.has_value && b.last_external.value != external.value)
		{
			power::publish_event(b.hub, external.value ? EXTERNAL_POWER_CONNECTED : EXTERNAL_POWER_DISCONNECTED, 0);
		}
		b.last_external = external;
	}
}
