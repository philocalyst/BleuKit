<*
 Monotonic timeouts. Wall-clock time can jump (NTP, suspend, the user); waits
 in Bleu are always measured against the monotonic clock.
*>
module bleu::deadline;
import std::time, std::time::clock, std::thread;

struct Deadline
{
	bool unbounded;
	Clock at;
}

<* A deadline `timeout` from now; `time::FOREVER` never expires. *>
fn Deadline after(Duration timeout) @inline
{
	if (timeout == time::FOREVER) return { .unbounded = true };
	return { .at = clock::now() + timeout };
}

fn bool Deadline.expired(self) @inline => !self.unbounded && clock::now() >= self.at;

<* Time left, never negative; `time::FOREVER` when unbounded. *>
fn Duration Deadline.remaining(self)
{
	if (self.unbounded) return time::FOREVER;
	NanoDuration left = self.at - clock::now();
	return left <= time::NANO_DURATION_ZERO ? time::DURATION_ZERO : left.to_duration();
}

<*
 Block on `cond` with `mutex` held (as with any condition variable) until it
 is signalled or the deadline passes. Spurious wake-ups are possible, so always
 call this in a loop that re-tests the predicate.

 @return "false when the deadline has passed. The predicate may have become true at the same moment, so re-test it once before giving up"
*>
fn bool Deadline.wait(self, ConditionVariable* cond, Mutex* mutex)
{
	if (self.unbounded)
	{
		cond.wait(mutex)!!;
		return true;
	}
	Duration left = self.remaining();
	if (left <= time::DURATION_ZERO) return false;
	// WAIT_TIMEOUT is the normal end of a timed wait: the loop re-tests the predicate
	// and the deadline. Any other fault would mean a condition variable or mutex that
	// is not initialised or not held, which is a bug in the caller, not a timeout.
	if (catch err = cond.wait_timeout(mutex, left))
	{
		if (err != thread::WAIT_TIMEOUT) unreachable("timed wait on an initialised condition variable failed");
	}
	return !self.expired();
}