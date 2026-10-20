<*
 The rollback rule for a change that must be confirmed: the new layout stays only if `confirm`
 arrives before the deadline; otherwise the caller restores the previous layout. A pure state
 machine: every call takes the current monotonic instant, so the rule is tested without waiting.
*>
module bleu::display;
import std::time, std::time::clock;

const ulong NANOS_PER_MICRO = 1000;

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
	self.deadline = (Clock)((ulong)now + (ulong)timeout * NANOS_PER_MICRO);
}

<*
 Confirm the pending change. Returns true when it was armed and the confirmation is in time. A
 confirmation after the deadline returns false and leaves the guard armed, so the caller still
 rolls back.
*>
fn bool RevertGuard.confirm(&self, Clock now)
{
	if (!self.armed || now > self.deadline) return false;
	self.armed = false;
	return true;
}

<* True when the guard is armed and its deadline has passed: roll back now. *>
fn bool RevertGuard.due(self, Clock now) @inline => self.armed && now >= self.deadline;

<* Forget the pending change without rolling it back: a newer configuration took its place. *>
fn void RevertGuard.disarm(&self) @inline
{
	self.armed = false;
}

<* How long the caller may sleep before the guard is due: zero when already due, forever when not armed. *>
fn Duration RevertGuard.remaining(self, Clock now)
{
	if (!self.armed) return time::FOREVER;
	if (now >= self.deadline) return time::DURATION_ZERO;
	return (Duration)(((ulong)self.deadline - (ulong)now) / NANOS_PER_MICRO);
}
