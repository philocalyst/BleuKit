<*
 Choosing the mechanisms a request may use, in the order to try them.

 Pure: it reads a device's controls and says what to try. The executor in
 `apply.c3` does the trying, and the policy rules are in `PolicyKind`.
*>
module bleu::brightness;
import bleu::error;

<* Most mechanisms one device can carry: one control per `Mechanism` value. *>
const usz MAX_CONTROLS = 6;

<* The control of `device` for `mechanism`, or null when the device has none. *>
fn Control* Device.control(&self, Mechanism mechanism)
{
	foreach (&control : self.controls)
	{
		if (control.mechanism == mechanism) return control;
	}
	return null;
}

<*
 Fill `out` with the mechanisms `policy` allows `device` to use, in the order
 to try them. Only writable controls are listed.

 @param out : "Room for `MAX_CONTROLS` mechanisms"
 @return "How many mechanisms were written to `out`; zero means the request cannot be carried out"
*>
fn usz candidates(Device* device, Policy policy, Mechanism[] out)
{
	if (policy.kind == EXACT)
	{
		Control* control = device.control(policy.mechanism);
		if (!control || !control.writable) return 0;
		out[0] = policy.mechanism;
		return 1;
	}
	usz n = append_writable(device, false, out);
	if (policy.kind == ALLOW_SOFTWARE || n == 0)
	{
		n += append_writable(device, true, out[n:out.len - (sz)n]);
	}
	return n;
}

// Append the writable controls that are software (`software`) or hardware, in preference order.
fn usz append_writable(Device* device, bool software, Mechanism[] out) @private
{
	usz n = 0;
	foreach (&control : device.controls)
	{
		if (!control.writable || control.mechanism.is_software() != software) continue;
		out[n++] = control.mechanism;
	}
	return n;
}

<*
 The fault for a request that no control can carry. An `EXACT` request names
 its control's reason; any other request says the device has nothing writable.
*>
fn fault refusal(Device* device, Policy policy)
{
	if (policy.kind == EXACT)
	{
		Control* control = device.control(policy.mechanism);
		if (!control)
		{
			return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "device '%s' has no control for that mechanism", device.id);
		}
		if (control.availability.ok())
		{
			return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "control of '%s' is read-only", device.id);
		}
		return error::raise(control.availability.refusal(), error::Domain.INTERNAL, 0, "%s", control.availability.note);
	}
	return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "device '%s' has no writable control", device.id);
}
