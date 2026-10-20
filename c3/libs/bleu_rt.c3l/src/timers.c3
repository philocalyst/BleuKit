<*
 One-shot and repeating timers on the monotonic clock, keyed by caller-chosen ids.

 The queue is a binary min-heap ordered by due time. The owning worker asks
 `next_timeout` for how long its poller may sleep, and calls `pop_expired` after
 each wake-up. It does no timekeeping of its own: `std::time::clock` is
 CLOCK_MONOTONIC (clock_gettime(2)), so wall-clock jumps never fire or delay a
 timer. Cancelling is by id and linear in the number of timers; a shell has a
 few dozen timers at most, so the simplicity is worth more than an index.

 Not thread-safe: the owning worker uses it.
*>
module bleu::rt::timers;
import std::time, std::time::clock, std::collections::list, bleu::error;

<*
 One pending timer. `period` is zero for a one-shot timer.
*>
struct Timer
{
	usz id;
	Clock due;
	Duration period;
}

<*
 A set of timers. Create with `init`, release with `free`.
*>
struct TimerQueue
{
	List{Timer} heap;
}

<* Create an empty queue whose storage comes from `allocator`. *>
fn void TimerQueue.init(&self, Allocator allocator)
{
	self.heap.init(allocator);
}

<* Release the storage. Pending timers are discarded. *>
fn void TimerQueue.free(&self)
{
	self.heap.free();
}

<*
 Fire `id` once, `delay` from now.

 @param delay : "How long from now; zero or less fires at the next `pop_expired`"
 @return? error::INVALID_ARGUMENT : "A timer with this id is already pending"
*>
fn void? TimerQueue.schedule(&self, usz id, Duration delay)
{
	return timer_add(self, id, delay, time::DURATION_ZERO);
}

<*
 Fire `id` every `period`, starting `period` from now. A missed period (the
 owner was busy) is not replayed as a burst: the next firing is `period` after
 the moment it is noticed.

 @return? error::INVALID_ARGUMENT : "A timer with this id is already pending, or the period is not positive (a zero period would fire on every poll, so it is refused rather than made one-shot)"
*>
fn void? TimerQueue.schedule_repeating(&self, usz id, Duration period)
{
	if (period <= time::DURATION_ZERO)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "repeating period must be positive")~;
	}
	return timer_add(self, id, period, period);
}

<*
 Remove the pending timer with this id.

 @return? NOT_FOUND : "No pending timer has this id"
*>
fn void? TimerQueue.cancel(&self, usz id)
{
	sz index = timer_find(self, id);
	if (index < 0) return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no timer with id %d", id)~;
	timer_remove_at(self, index);
}

<*
 How long until the earliest timer fires. Zero when one is already due;
 `time::FOREVER` when there are no timers at all.
*>
fn Duration TimerQueue.next_timeout(&self)
{
	if (self.heap.is_empty()) return time::FOREVER;
	NanoDuration left = self.heap.get(0).due - clock::now();
	return left <= time::NANO_DURATION_ZERO ? time::DURATION_ZERO : left.to_duration();
}

<*
 Write the ids of timers that have fired into `buffer`, earliest first, and
 return how many. One-shot timers leave the queue; repeating timers are rearmed.
 Timers that did not fit stay due, so the next call returns them.

 @param buffer : "Receives the expired ids; it must have room for at least one"
 @require buffer.len > 0 : "An empty buffer never drains a due timer, so `next_timeout` would stay at zero"
*>
fn usz TimerQueue.pop_expired(&self, usz[] buffer)
{
	Clock now = clock::now();
	usz n     = 0;
	while (n < (usz)buffer.len && !self.heap.is_empty() && self.heap.get(0).due <= now)
	{
		Timer top = self.heap.get(0);
		buffer[n++] = top.id;
		if (top.period == time::DURATION_ZERO)
		{
			timer_remove_at(self, 0);
			continue;
		}
		Clock next = top.due + top.period;
		if (next <= now) next = now + top.period;
		top.due = next;
		self.heap.set(0, top);
		timer_sift_down(self, 0);
	}
	return n;
}

// Insert a timer. `period` zero means one-shot.
fn void? timer_add(TimerQueue* self, usz id, Duration delay, Duration period) @private
{
	if (timer_find(self, id) >= 0)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "timer %d is already pending", id)~;
	}
	self.heap.push({ .id = id, .due = clock::now() + delay, .period = period });
	timer_sift_up(self, self.heap.len() - 1);
}

// Index of the timer with this id, or -1.
fn sz timer_find(TimerQueue* self, usz id) @private
{
	for (sz i = 0; i < self.heap.len(); i++)
	{
		if (self.heap.get(i).id == id) return i;
	}
	return -1;
}

// Remove the timer at `index` and restore the heap order.
fn void timer_remove_at(TimerQueue* self, sz index) @private
{
	sz last = self.heap.len() - 1;
	if (index != last) self.heap.set(index, self.heap.get(last));
	self.heap.remove_last()!!;
	if (index < self.heap.len())
	{
		timer_sift_down(self, index);
		timer_sift_up(self, index);
	}
}

fn void timer_sift_up(TimerQueue* self, sz index) @private
{
	sz i = index;
	while (i > 0)
	{
		sz parent = (i - 1) / 2;
		if (self.heap.get(parent).due <= self.heap.get(i).due) return;
		self.heap.swap(i, parent);
		i = parent;
	}
}

fn void timer_sift_down(TimerQueue* self, sz index) @private
{
	sz i     = index;
	sz count = self.heap.len();
	while (true)
	{
		sz smallest = i;
		sz left     = 2 * i + 1;
		sz right    = left + 1;
		if (left < count && self.heap.get(left).due < self.heap.get(smallest).due) smallest = left;
		if (right < count && self.heap.get(right).due < self.heap.get(smallest).due) smallest = right;
		if (smallest == i) return;
		self.heap.swap(i, smallest);
		i = smallest;
	}
}