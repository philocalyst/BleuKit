<*
 The JSON of one state: `{"generation": n, "state": ...}`. Generic over the state
 type, so the services that share it need no code of their own.
*>
module bleu::registry::state_json <State>;
import bleu::observe, bleu::json;

<*
 Write `{"generation": n, "state": ...}` for one snapshot. A reply also starts with
 `"ok": true`, as every method result does; a topic's payload does not.

 @param out : "Writer at the top level or inside a value; its position is kept"
 @param as_reply : "True for a method's result, false for a topic's payload"
*>
fn void? write(json::JsonWriter* out, Snapshot{State}* snapshot, bool as_reply)
{
	out.begin_object()!;
	if (as_reply)
	{
		out.key("ok")!;
		out.put_bool(true)!;
	}
	out.key("generation")!;
	out.put_uint(snapshot.generation)!;
	out.key("state")!;
	json::write(out, snapshot.value)!;
	return out.end_object();
}