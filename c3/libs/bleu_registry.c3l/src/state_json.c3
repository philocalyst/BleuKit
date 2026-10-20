<*
 The JSON of one state: `{"generation": n, "state": ...}`. Generic over the state
 type, so the services that share it need no code of their own.
*>
module bleu::registry::state_json <State>;
import bleu::observe, bleu::json;

<*
 Write `{"generation": n, "state": ...}` for one snapshot.

 @param out : "Writer at the top level or inside a value; its position is kept"
*>
fn void? write(json::JsonWriter* out, Snapshot{State}* snapshot)
{
	out.begin_object()!;
	out.key("generation")!;
	out.put_uint(snapshot.generation)!;
	out.key("state")!;
	json::write(out, snapshot.value)!;
	return out.end_object();
}
