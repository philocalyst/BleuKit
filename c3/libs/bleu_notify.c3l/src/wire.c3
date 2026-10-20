<*
 The arguments of an incoming Notify call, read and bounded.

 `s u s s s as a{sv} i`: app name, replaces id, app icon, summary, body, actions,
 hints, timeout. Every string is copied into the allocator given and cut to its
 limit (see `bleu::notify` for the limits); actions are paired up (an odd last
 string is dropped), duplicates and pairs past the limit are dropped; the timeout
 is kept in -1 .. one day.
*>
module bleu::notify::wire;
import bleu::error, bleu::dbus::marshal, bleu::notify, bleu::notify::hints, bleu::notify::text;

<* The decoded arguments of one Notify call. Strings and arrays live in the allocator given to `read_notify`. *>
struct Incoming
{
	String app_name;
	notify::NoteId replaces_id;
	String app_icon;
	String summary;
	String body;
	notify::Action[] actions;
	int expire_ms;
	hints::Hints hints;
}

<*
 Read the arguments of a Notify call, which must be positioned at its first argument.

 @param allocator : "Allocator for every string and array of `out`"
 @param [&inout] out : "Overwritten"
 @return? error::PROTOCOL : "The arguments do not match the Notify signature"
*>
fn void? read_notify(Reader* r, Allocator allocator, Incoming* out)
{
	out.app_name = text::truncate(r.read_string()!, notify::MAX_APP_NAME).copy(allocator);
	out.replaces_id = (notify::NoteId)r.read_u32()!;
	out.app_icon = text::truncate(r.read_string()!, notify::MAX_ICON).copy(allocator);
	out.summary = text::truncate(r.read_string()!, notify::MAX_SUMMARY).copy(allocator);
	out.body = text::truncate(r.read_string()!, notify::MAX_BODY).copy(allocator);
	out.actions = read_actions(r, allocator)!;
	hints::decode(r, allocator, &out.hints)!;
	out.expire_ms = clamp_expire(r.read_i32()!);
}

<* Timeouts below -1 mean the server default, as -1 does; very long ones are capped at a day. *>
fn int clamp_expire(int expire_ms)
{
	if (expire_ms < -1) return -1;
	if (expire_ms > notify::MAX_EXPIRE_MS) return notify::MAX_EXPIRE_MS;
	return expire_ms;
}

<*
 Read the `as` action list as (key, label) pairs. Pairs with an empty key or a
 key already seen are dropped, as are pairs past `MAX_ACTIONS`.
*>
fn notify::Action[]? read_actions(Reader* r, Allocator allocator)
{
	notify::Action[notify::MAX_ACTIONS] pairs;
	usz kept      = 0;
	String key    = "";
	bool have_key = false;
	r.begin_array()!;
	while (r.has_more())
	{
		String word = r.read_string()!;
		if (!have_key)
		{
			key = word;
			have_key = true;
			continue;
		}
		have_key = false;
		if (kept == notify::MAX_ACTIONS || key.len == 0) continue;
		String clipped = text::truncate(key, notify::MAX_ACTION_KEY);
		if (contains_key(pairs[:kept], clipped)) continue;
		pairs[kept++] = {
			.key = clipped.copy(allocator),
			.label = text::truncate(word, notify::MAX_ACTION_LABEL)
			.copy(allocator), };
	}
	r.end_array()!;
	if (kept == 0) return { };
	notify::Action[] actions = alloc::new_array(allocator, notify::Action, (sz)kept);
	foreach (i, pair : pairs[:kept]) actions[i] = pair;
	return actions;
}

fn bool contains_key(notify::Action[] pairs, String key)
{
	foreach (pair : pairs) if (pair.key == key) return true;
	return false;
}