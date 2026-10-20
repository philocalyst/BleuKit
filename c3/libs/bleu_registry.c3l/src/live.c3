<*
 The generic adapters every service shares. Instantiated once per service with
 its handle type `Svc`, its state type `State` and its capability enum `Cap`,
 for example `live::state{battery::Battery, battery::State, battery::Cap}`.

 Each function takes the handle as `void*` so that one table of function
 pointers can hold every service. Nothing here is specific to one service.
*>
module bleu::registry::live <Svc, State, Cap>;
import std::time, bleu::observe, bleu::json, bleu::availability, bleu::registry;

<* Longest a read waits for a service's first reading. *>
const Duration FIRST_STATE_TIMEOUT = (Duration)5_000_000;

<*
 Write `{"generation": n, "state": ...}` for one snapshot.

 @param out : "Writer at the top level or inside a value; its position is kept"
*>
fn void? write_snapshot(json::JsonWriter* out, Snapshot{State}* snapshot)
{
	out.begin_object()!;
	out.key("generation")!;
	out.put_uint(snapshot.generation)!;
	out.key("state")!;
	json::write(out, snapshot.value)!;
	return out.end_object();
}

<*
 Write the latest state. A service that has not produced its first reading yet is
 waited for up to `FIRST_STATE_TIMEOUT`; once a reading exists this returns at once.
*>
fn void? state(void* handle, json::JsonWriter* out)
{
	Svc* svc = (Svc*)handle;
	Snapshot{State}* snapshot = svc.wait_after(0, FIRST_STATE_TIMEOUT)!;
	defer snapshot.release();
	return write_snapshot(out, snapshot);
}

fn void? state_after(void* handle, ulong seen, Duration timeout, json::JsonWriter* out)
{
	Svc* svc = (Svc*)handle;
	Snapshot{State}* snapshot = svc.wait_after(seen, timeout)!;
	defer snapshot.release();
	return write_snapshot(out, snapshot);
}

<* Write the capabilities as an array; each entry is `{"cap", "reason", "note"}`. *>
fn void? capabilities(void* handle, json::JsonWriter* out)
{
	Svc* svc = (Svc*)handle;
	out.begin_array()!;
	for (usz i = 0; i < Cap::len; i++)
	{
		Cap cap = Cap::from_ordinal(i);
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
	return out.end_array();
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

<*
 Deliver each state to `tap` as one JSON text. Runs on the publishing thread,
 so it only formats into temporary memory and calls the sink.
*>
fn void tap_listener(void* context, Snapshot{State}* snapshot)
{
	Tap* tap = (Tap*)context;
	@pool()
	{
		json::JsonWriter out;
		DString buffer;
		buffer.init(tmem);
		out.init_dstring(&buffer);
		// Serialising a plain-data state cannot fail except by running out of memory, which aborts.
		write_snapshot(&out, snapshot)!!;
		tap.sink(tap.context, out.written());
	};
}

fn void? watch(void* handle, Tap* tap)
{
	Svc* svc = (Svc*)handle;
	svc.watch(&tap_listener, tap);
}
