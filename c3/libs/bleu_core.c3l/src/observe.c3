<*
 Level-triggered state publication.

 A service keeps one `Observable{State}`. Whenever the world changes, its
 backend builds a complete, immutable `Snapshot` and publishes it. Consumers
 never see partial updates and never lose one: they either read the current
 snapshot, block until a newer generation exists, or register a listener.
 Because every snapshot is the *whole* state, a consumer that missed any number
 of intermediate states is automatically resynchronised by the next one.

 Snapshots own an arena. Everything referenced from `State` (strings, arrays,
 nested records) must be allocated from `Snapshot.allocator()`; releasing the
 last reference frees all of it at once.

 Two locks. `mutex` guards the state and is never held while user code runs.
 `delivery` is held while a publication calls its listeners, and by `watch`,
 `unwatch` and `close` when they are called from outside a listener. So listeners
 run one at a time, in publication order, and an `unwatch` from another thread
 waits for the listener it removes to finish.
*>
module bleu::observe <State>;
import std::thread, std::atomic, std::time, std::collections::list, bleu::error, bleu::deadline;

<*
 Called with the new snapshot, on the thread that publishes it (or, for the first
 call from `watch`, on the thread that registers the listener). A listener may call
 `latest`, `wait_after` with a timeout, `watch`, `unwatch` (except for itself) and
 `close`. It must not publish to the same observable, which would deadlock, and it
 must not block: a `wait_after` without timeout waits for a publication that can
 only come from the thread it is blocking. The snapshot is only borrowed for the
 duration of the call: `retain()` to keep it.
*>
alias Listener = fn void(void* context, Snapshot* snapshot);

struct Snapshot
{
	Atomic{int} refs;
	Allocator parent;
	DynamicArenaAllocator arena;
	ulong generation;
	State value;
}

<*
 Start building a snapshot holding one reference (the caller's).

 @param [&inout] parent : "Allocator for the snapshot and its arena pages"
 @return "A snapshot with zero-initialised `value`"
*>
fn Snapshot* begin(Allocator parent)
{
	Snapshot* s = alloc::new(parent, Snapshot);
	s.parent = parent;
	s.arena.init(parent, 4096);
	s.refs.store(1);
	return s;
}

<* Allocator that owns the memory of this snapshot's `value`. *>
fn Allocator Snapshot.allocator(&self) @inline => &self.arena;

<* Take an additional reference. *>
fn Snapshot* Snapshot.retain(&self)
{
	self.refs.add(1);
	return self;
}

<* Drop a reference; the last one frees the snapshot and everything in it. *>
fn void Snapshot.release(&self)
{
	if (self.refs.sub(1) != 1) return;
	Allocator parent = self.parent;
	self.arena.free();
	alloc::free(parent, self);
}

struct Watcher @private
{
	Listener listener;
	void* context;
	uint id;
}

<*
 A published state with its listeners. Create it with `init`, and release it with
 `close` followed by `destroy`.

 Watcher ids grow with registration order, and `watchers` keeps that order, so a
 publication can visit the listeners in turn by id.
*>
struct Observable
{
	Mutex mutex;               // guards every field below except `delivery`
	Mutex delivery;            // held while listeners run; see the module comment
	ConditionVariable changed;
	Snapshot* current;
	ulong generation;
	bool closed;
	List{Watcher} watchers;
	uint next_watch_id;
	List{uint} running;        // ids of the listeners on the stack of `notifier`, innermost last
	Thread notifier;           // the thread running the listeners in `running`
}

<* Opaque registration returned by `watch`. 0 means "not registered" (the observable is closed). *>
typedef WatchId = uint;

<*
 Create an open observable with no state yet.

 @param [&inout] allocator : "Allocator for the listener lists"
*>
fn void Observable.init(&self, Allocator allocator)
{
	*self = { };
	self.mutex.init()!!;
	self.delivery.init()!!;
	self.changed.init()!!;
	self.watchers.init(allocator);
	self.running.init(allocator);
}

<*
 Close the observable: release its current snapshot, wake every waiter with
 `DISCONNECTED`, and refuse later publications and registrations. Called from another
 thread it waits for a listener that is running; called from inside a listener it
 returns at once, and that listener finishes normally. Idempotent.
*>
fn void Observable.close(&self)
{
	bool nested = self.on_notifier_thread();
	if (!nested) self.delivery.lock()!!;
	self.mutex.lock()!!;
	self.closed = true;
	Snapshot* old = self.current;
	self.current = null;
	self.changed.broadcast()!!;
	self.mutex.unlock();
	if (!nested) self.delivery.unlock();
	if (old) old.release();
}

<*
 Release the locks and lists. Call once, after `close`, when no other thread can
 reach the observable.
*>
fn void Observable.destroy(&self)
{
	self.close();
	self.watchers.free();
	self.running.free();
	self.changed.destroy()!!;
	self.delivery.destroy();
	self.mutex.destroy();
}

<*
 Publish a new complete state. Takes ownership of the caller's reference.
 Generations increase by exactly one per publication. Every listener registered
 before this call sees the snapshot before `publish` returns. Publications are
 serialised, so listeners see generations in order even with several publishers.

 @require !self.on_notifier_thread() : "publish from inside a listener would deadlock"
 @param [&inout] snapshot : "Built with `begin`; must not be modified afterwards"
 @return "The generation assigned to it"
*>
fn ulong Observable.publish(&self, Snapshot* snapshot)
{
	self.delivery.lock()!!;
	defer self.delivery.unlock();
	self.mutex.lock()!!;
	if (self.closed)
	{
		self.mutex.unlock();
		snapshot.release();
		return self.generation;
	}
	snapshot.generation = ++self.generation;
	Snapshot* old = self.current;
	self.current = snapshot;
	// The delivery keeps its own reference, so the snapshot outlives a publication
	// that replaces it while listeners still borrow it.
	snapshot.retain();
	ulong generation = self.generation;
	uint newest = self.next_watch_id;
	self.changed.broadcast()!!;
	self.mutex.unlock();
	deliver(self, snapshot, newest);
	snapshot.release();
	if (old) old.release();
	return generation;
}

<*
 The newest snapshot, retained for the caller, or `UNAVAILABLE` before the
 first publication (and after `close`).
*>
fn Snapshot*? Observable.latest(&self)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	if (!self.current) return error::UNAVAILABLE~;
	return self.current.retain();
}

<*
 Block until a snapshot newer than `seen` exists and return it (retained).

 @param seen : "Generation the caller already has; pass 0 for 'anything'"
 @param timeout : "How long to wait; `time::FOREVER` blocks until published/closed"
 @return? TIMEOUT : "Nothing newer arrived in time"
 @return? error::DISCONNECTED : "The observable was closed"
*>
fn Snapshot*? Observable.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	Deadline deadline = deadline::after(timeout);
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	while (!self.closed && self.generation <= seen)
	{
		// A false means the deadline passed; re-test the predicate once more below.
		if (!deadline.wait(&self.changed, &self.mutex)) break;
	}
	if (self.closed) return error::DISCONNECTED~;
	if (self.generation <= seen) return TIMEOUT~;
	return self.current.retain();
}

<*
 Register a listener. It is called at once with the current snapshot (if there is
 one) on the calling thread, then on the publishing thread for every later
 publication. The first call runs outside the state lock and while no publication
 is running, so the listener sees the calls in order.

 @return "Token for `unwatch`; 0 when the observable is already closed (nothing was registered)"
*>
fn WatchId Observable.watch(&self, Listener listener, void* context)
{
	bool nested = self.on_notifier_thread();
	if (!nested) self.delivery.lock()!!;
	self.mutex.lock()!!;
	if (self.closed)
	{
		self.mutex.unlock();
		if (!nested) self.delivery.unlock();
		return (WatchId)0;
	}
	uint id = ++self.next_watch_id;
	self.watchers.push({ listener, context, id });
	Snapshot* current = self.current;
	if (current) current.retain();
	self.mutex.unlock();
	if (current)
	{
		self.enter(id);
		listener(context, current);
		self.leave();
		current.release();
	}
	if (!nested) self.delivery.unlock();
	return (WatchId)id;
}

<*
 Remove a listener. When this returns the listener is not running and will not be
 called again. Waits for a listener running on another thread to finish.

 Called from inside a listener, it refuses to remove that listener or any listener
 still running below it on the same thread, because it would have to wait for
 itself. Other listeners of the same observable may be removed from inside one.

 @return? error::INVALID_STATE : "Called from inside the listener it would remove"
*>
fn void? Observable.unwatch(&self, WatchId token)
{
	bool nested = self.on_notifier_thread();
	if (nested)
	{
		if (self.is_running((uint)token))
		{
			return error::raise(
				error::INVALID_STATE,
				error::Domain.INTERNAL,
				0,
				"a listener cannot unwatch itself or a listener it runs inside"
			)~;
		}
	}
	else self.delivery.lock()!!;
	self.mutex.lock()!!;
	foreach (i, &w : self.watchers)
	{
		if (w.id != (uint)token) continue;
		self.watchers.remove_at(i);
		break;
	}
	self.mutex.unlock();
	if (!nested) self.delivery.unlock();
}

// True when the calling thread is running a listener of this observable.
fn bool Observable.on_notifier_thread(&self)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	return !self.running.is_empty() && thread::current().equals(self.notifier);
}

// True when the listener `id` is on the stack of running listeners.
fn bool Observable.is_running(&self, uint id)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	foreach (running : self.running)
	{
		if (running == id) return true;
	}
	return false;
}

// Record that a listener `id` starts on this thread. The first one makes this thread the notifier.
fn void Observable.enter(&self, uint id)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	if (self.running.is_empty()) self.notifier = thread::current();
	self.running.push(id);
}

// Record that the innermost running listener has returned.
fn void Observable.leave(&self)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	self.running.remove_last()!!;
}

// Copy out the next listener due for a publication: the first one with an id in
// (`after`, `newest`]. It is marked as running. False when none is left, or the
// observable was closed meanwhile.
fn bool Observable.enter_next(&self, uint after, uint newest, Watcher* out)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	if (self.closed) return false;
	foreach (w : self.watchers)
	{
		if (w.id <= after || w.id > newest) continue;
		if (self.running.is_empty()) self.notifier = thread::current();
		self.running.push(w.id);
		*out = w;
		return true;
	}
	return false;
}

// Call each listener due for `snapshot` in registration order. Entered with `delivery` held and the state lock released.
fn void deliver(Observable* self, Snapshot* snapshot, uint newest) @private
{
	uint after = 0;
	Watcher w;
	while (self.enter_next(after, newest, &w))
	{
		w.listener(w.context, snapshot);
		self.leave();
		after = w.id;
	}
}
