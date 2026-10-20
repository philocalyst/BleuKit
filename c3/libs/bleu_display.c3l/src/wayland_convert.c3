<*
 Conversions between Wayland wire values and display types, and the rule for a configuration the
 compositor cancelled because the layout moved under it. Pure: no sockets, runs on every host.
*>
module bleu::display::wayland_convert;
import bleu::display;

<*
 The transform a `wl_output.transform` value names. The protocol numbers its transforms in the same
 order as `display::Transform`, so the wire value is the ordinal. Values past the enum are NORMAL.
*>
fn display::Transform transform_from_wire(uint value)
{
	if (value > (uint)display::Transform.FLIPPED_R270) return display::Transform.NORMAL;
	return (display::Transform)value;
}

<* The wire value of a transform (see `transform_from_wire`). *>
fn uint transform_to_wire(display::Transform transform) @inline => (uint)transform;

<* A refresh rate on the wire (signed `int` millihertz); a negative value is "unknown" and becomes 0. *>
fn display::RefreshMilliHz refresh_from_wire(int millihertz) @inline => millihertz > 0 ? (uint)millihertz : 0;

<*
 What to do after a configuration came back `cancelled`. The compositor cancels when its state
 moved under the attempt, so the attempt's serial is stale.

 RETRY_NOW: the state already moved on, so a new attempt with the current serial is safe.
 WAIT_FOR_SERIAL: the new serial has not arrived yet; retry when it does.
 GIVE_UP: the layout moved twice; report it and let the caller read the state again.

 @param retried : "Whether this request was already retried once"
 @param attempt_serial : "The serial the cancelled attempt was created with"
 @param latest_serial : "The newest serial the compositor has announced"
*>
fn CancelAction after_cancel(bool retried, uint attempt_serial, uint latest_serial)
{
	if (retried) return GIVE_UP;
	return latest_serial != attempt_serial ? RETRY_NOW : WAIT_FOR_SERIAL;
}

<* See `after_cancel`. *>
enum CancelAction : char
{
	RETRY_NOW,
	WAIT_FOR_SERIAL,
	GIVE_UP,
}