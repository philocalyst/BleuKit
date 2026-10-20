<*
 Carrying out one write under a policy: pick the candidates, try them in order,
 and say which one worked. Shared by every platform; the platform supplies the
 `write` function. Runs on the worker thread.
*>
module bleu::brightness;
import bleu::error, bleu::unit;

<* The device of `state` with this id, or null. *>
fn Device* find_device(State* state, String device_id)
{
	foreach (&device : state.devices)
	{
		if (device.id == device_id) return device;
	}
	return null;
}

<*
 Move `device_id` to `level` under `policy`, using the controls of `state`.

 A candidate that fails moves on to the next one only as the policy allows (the
 candidate list already contains only what the policy allows). When every
 candidate fails, the last failure is returned.

 @param state : "The last published state; its writable flags decide the candidates"
 @return? NOT_FOUND : "No device has that id"
 @return? error::UNAVAILABLE, error::UNSUPPORTED, error::PERMISSION_DENIED : "No control can carry the request, or the last one tried failed"
*>
fn Applied? apply(Platform* platform, State* state, String device_id, Policy policy, Level level)
{
	Device* device = find_device(state, device_id);
	if (!device) return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no device '%s'", device_id)~;
	Mechanism[MAX_CONTROLS] order;
	usz count = candidates(device, policy, order[..]);
	if (count == 0)
	{
		fault refused = refusal(device, policy);
		return refused~;
	}
	fault last = error::UNAVAILABLE;
	for (usz i = 0; i < count; i++)
	{
		Applied? applied = platform.write(platform.context, device_id, order[i], level);
		if (catch err = applied)
		{
			last = err;
			continue;
		}
		return applied;
	}
	return last~;
}