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
*>
module bleu::observe <State>;
import std::thread, std::atomic, std::time, std::collections::list, bleu::error, bleu::deadline;

<*
 Called on the publishing thread with the new snapshot. It must be quick and
 must not block, publish to the same observable, or call `unwatch` on it. The
 snapshot is only borrowed for the duration of the call: `retain()` to keep it.
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

struct Observable
{
	Mutex mutex;
	ConditionVariable changed;
	Snapshot* current;
	ulong generation;
	bool closed;
	List{Watcher} watchers;
	uint next_watch_id;
	Thread notifying; // thread currently inside a listener, if any
	bool in_notify;
}

<* Opaque registration returned by `watch`. *>
typedef WatchId = uint;

<*
 @param [&inout] allocator : "Allocator for the watcher list"
*>
fn void Observable.init(&self, Allocator allocator)
{
	*self = { };
	self.mutex.init()!!;
	self.changed.init()!!;
	self.watchers.init(allocator);
}

<*
 Release the current snapshot and wake every waiter with `DISCONNECTED`.
 No listener is running once this returns.
*>
fn void Observable.close(&self)
{
	Snapshot* old;
	self.mutex.lock()!!;
	self.closed = true;
	old = self.current;
	self.current = null;
	self.watchers.clear();
	self.changed.broadcast()!!;
	self.mutex.unlock();
	if (old) old.release();
}

<*
 Publish a new complete state. Takes ownership of the caller's reference.
 Generations increase by exactly one per publication.

 @param [&inout] snapshot : "Built with `begin`; must not be modified afterwards"
 @return "The generation assigned to it"
*>
fn ulong Observable.publish(&self, Snapshot* snapshot)
{
	Snapshot* old;
	self.mutex.lock()!!;
	if (self.closed)
	{
		self.mutex.unlock();
		snapshot.release();
		return self.generation;
	}
	snapshot.generation = ++self.generation;
	old = self.current;
	self.current = snapshot;
	// Listeners run under the lock so that registration, delivery and removal
	// are totally ordered: after `unwatch` returns no callback can still run.
	self.notifying = thread::current();
	self.in_notify = true;
	foreach (&w : self.watchers) w.listener(w.context, snapshot);
	self.in_notify = false;
	ulong generation = self.generation;
	self.changed.broadcast()!!;
	self.mutex.unlock();
	if (old) old.release();
	return generation;
}

<*
 The newest snapshot, retained for the caller, or `UNAVAILABLE` before the
 first publication.
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
		if (!deadline.wait(&self.changed, &self.mutex)) return TIMEOUT~;
	}
	if (self.closed) return error::DISCONNECTED~;
	return self.current.retain();
}

<*
 Register a listener. It is called immediately with the current snapshot (if
 any), then for every later publication.

 @return "Token for `unwatch`"
*>
fn WatchId Observable.watch(&self, Listener listener, void* context)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	uint id = ++self.next_watch_id;
	self.watchers.push({ listener, context, id });
	if (self.current) listener(context, self.current);
	return (WatchId)id;
}

<*
 Remove a listener. When this returns the listener is not running and will not
 be called again.

 @require !self.in_notify || !self.notifying.equals(thread::current()) : "unwatch from inside a listener would deadlock"
*>
fn void Observable.unwatch(&self, WatchId token)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	foreach (i, &w : self.watchers)
	{
		if (w.id != (uint)token) continue;
		self.watchers.remove_at(i);
		return;
	}
}