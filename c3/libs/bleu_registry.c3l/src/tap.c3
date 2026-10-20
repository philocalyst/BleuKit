<*
 The state watch of a service that has one. Kept apart from `live`, because
 a service without a watch (the keyring) must not have this instantiated.
*>
module bleu::registry::tap <Svc, State>;
import bleu::observe, bleu::json, bleu::registry, bleu::registry::state_json;

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
		state_json::write{State}(&out, snapshot, false)!!;
		tap.sink(tap.context, out.written());
	};
}

fn void? watch(void* handle, Tap* tap)
{
	Svc* svc = (Svc*)handle;
	svc.watch(&tap_listener, (void*)tap);
}
