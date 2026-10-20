<*
 The generic adapters every service shares. Instantiated once per service with
 its handle type `Svc`, its state type `State` and its capability enum `Cap`,
 for example `live::state{battery::Battery, battery::State, battery::Cap}`.

 Each function takes the handle as `void*` so that one table of function
 pointers can hold every service. Nothing here is specific to one service.
*>
module bleu::registry::live <Svc, State, Cap>;
import std::time, bleu::observe, bleu::json, bleu::availability, bleu::registry, bleu::registry::state_json;

<* Longest a read waits for a service's first reading. *>
const Duration FIRST_STATE_TIMEOUT = (Duration)5_000_000;


<*
 Write the latest state. A service that has not produced its first reading yet is
 waited for up to `FIRST_STATE_TIMEOUT`; once a reading exists this returns at once.
*>
fn void? state(void* handle, json::JsonWriter* out)
{
	Svc* svc                  = (Svc*)handle;
	Snapshot{State}* snapshot = svc.wait_after(0, FIRST_STATE_TIMEOUT)!;
	defer snapshot.release();
	return state_json::write{State}(out, snapshot, true);
}

fn void? state_after(void* handle, ulong seen, Duration timeout, json::JsonWriter* out)
{
	Svc* svc                  = (Svc*)handle;
	Snapshot{State}* snapshot = svc.wait_after(seen, timeout)!;
	defer snapshot.release();
	return state_json::write{State}(out, snapshot, true);
}

<* Write `{"ok": true, "capabilities": [...]}`; each entry is `{"cap", "reason", "note"}`. *>
fn void? capabilities(void* handle, json::JsonWriter* out)
{
	Svc* svc = (Svc*)handle;
	out.begin_object()!;
	out.key("ok")!;
	out.put_bool(true)!;
	out.key("capabilities")!;
	out.begin_array()!;
	for (usz i = 0; i < Cap::len; i++)
	{
		Cap cap                   = Cap::from_ordinal(i);
		Availability availability = svc.capability(cap);
		out.begin_object()!;
		out.key("cap")!;
		json::write(out, cap)!;
		out.key("reason")!;
		json::write(out, availability.reason)!;
		out.key("note")!;
		out.put_string(availability.note)!;
		out.end_object()!;
	}
	out.end_array()!;
	return out.end_object();
}

fn String backend(void* handle)
{
	Svc* svc = (Svc*)handle;
	return svc.backend_name();
}

fn void close(void* handle)
{
	Svc* svc = (Svc*)handle;
	svc.close();
}