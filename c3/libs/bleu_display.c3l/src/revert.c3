<*
 The rollback rule for a change that must be confirmed: the new layout stays only if `confirm`
 arrives before the deadline; otherwise the caller restores the previous layout. A pure state
 machine: every call takes the current monotonic instant, so the rule is tested without waiting.

 One boundary for both rules: at the deadline itself a confirmation is already too late, and the
 rollback is already due.
*>
module bleu::display;
import bleu::error, std::time, std::time::clock;

const ulong NANOS_PER_MICRO = 1000;
const ulong SATURATED_NANOS = 0xFFFF_FFFF_FFFF_FFFF;

<*
 The rollback window when the caller passes zero: 15 seconds. `Display.apply` documents
 the other window values (FOREVER, and the refusal of a negative one).
*>
const Duration DEFAULT_REVERT_AFTER = (Duration)15_000_000;

<*
 The rollback window a caller asked for. Zero means DEFAULT_REVERT_AFTER, FOREVER means
 no rollback at all (the caller keeps the change, as with a plain APPLY), and any other
 value is the window itself.

 @return? error::INVALID_ARGUMENT : "The window is negative"
*>
fn Duration? revert_window(Duration requested)
{
	if (requested < time::DURATION_ZERO)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "revert_after is negative")~;
	}
	if (requested == time::DURATION_ZERO) return DEFAULT_REVERT_AFTER;
	return requested;
}

<*
 The monotonic instant `timeout` after `now`. It saturates at the largest instant instead of
 wrapping, so FOREVER never comes due; a timeout of zero or less is already due.
*>
fn Clock deadline_after(Clock now, Duration timeout)
{
	if (timeout <= time::DURATION_ZERO) return now;
	ulong start  = (ulong)now;
	ulong micros = (ulong)timeout;
	ulong span   = micros > SATURATED_NANOS / NANOS_PER_MICRO ? SATURATED_NANOS : micros * NANOS_PER_MICRO;
	return (Clock)(span > SATURATED_NANOS - start ? SATURATED_NANOS : start + span);
}

<* One pending confirmation. `deadline` is a monotonic instant. *>
struct RevertGuard
{
	bool armed;
	Clock deadline;
}

<* Start waiting for a confirmation that must arrive within `timeout` of `now`. Arming replaces any earlier deadline. *>
fn void RevertGuard.arm(&self, Clock now, Duration timeout)
{
	self.armed = true;
	self.deadline = deadline_after(now, timeout);
}

<*
 Confirm the pending change. Returns true when it was armed and the confirmation came before the
 deadline. A confirmation at or after the deadline returns false and leaves the guard armed, so
 the caller still rolls back.
*>
fn bool RevertGuard.confirm(&self, Clock now)
{
	if (!self.armed || now >= self.deadline) return false;
	self.armed = false;
	return true;
}

<* True when the guard is armed and its deadline has been reached: roll back now. *>
fn bool RevertGuard.due(self, Clock now) @inline => self.armed && now >= self.deadline;

<* Forget the pending change without rolling it back: a newer configuration took its place. *>
fn void RevertGuard.disarm(&self) @inline
{
	self.armed = false;
}

<*
 How long the caller may sleep before the guard is due: zero when already due, forever when not armed.
 Rounded up to whole microseconds, so a deadline that is not yet reached never reports zero.
*>
fn Duration RevertGuard.remaining(self, Clock now)
{
	if (!self.armed) return time::FOREVER;
	if (now >= self.deadline) return time::DURATION_ZERO;
	ulong nanos = (ulong)self.deadline - (ulong)now;
	return (Duration)((nanos + NANOS_PER_MICRO - 1) / NANOS_PER_MICRO);
}