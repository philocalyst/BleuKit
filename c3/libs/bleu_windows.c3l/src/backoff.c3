module bleu::windows;
import std::time;

<*
 Waits between reconnect attempts: each wait doubles the one before, up to a
 limit, and `reset` returns to the first wait after a success. Pure, so the
 policy is tested without a socket.
*>
struct Backoff
{
	Duration first;
	Duration limit;
	Duration next;
}

<*
 Start a sequence.

 @param first : "The first wait"
 @param limit : "The longest wait; later waits stay at this value"
*>
fn void Backoff.init(&self, Duration first, Duration limit)
{
	*self = { .first = first, .limit = limit, .next = first };
}

<* The wait to use now; the one after it is doubled, up to the limit. *>
fn Duration Backoff.take(&self)
{
	Duration wait    = self.next;
	Duration doubled = (Duration)(2 * (long)wait);
	self.next = doubled > self.limit ? self.limit : doubled;
	return wait;
}

<* Return to the first wait, after a successful attempt. *>
fn void Backoff.reset(&self) => self.next = self.first;