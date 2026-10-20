<*
 The link between the service and the holds and inhibitors it hands out.

 A hold or an inhibitor is a value the caller keeps, and it releases itself through
 its link. The link is reference-counted: the service owns one reference, and every
 live handle owns one. `Power.close` drops the service's reference after it has
 closed the link, so a release that comes after close finds the link still allocated,
 sees that the service is closed, and is refused with DISCONNECTED. The link is freed
 with its last reference, so no release touches freed memory.

 A handle is released once. Copies of a handle are copies of one reference and must
 not both be released; `release()` on the same handle again is a no-op.
*>
module bleu::power;
import std::thread, bleu::error;

<*
 The reference-counted state shared by a service and its handles. `hub` is the
 service's hub and is only used while `open`. Every access is under `mutex`.
*>
struct Link
{
	Allocator allocator;
	Mutex mutex;
	PowerHub* hub;
	bool open;
	uint references; // the service's own, plus one per live handle
}

<* A new link for a service that is open, holding the service's reference. *>
fn Link* link_create(Allocator allocator, PowerHub* hub)
{
	Link* link = alloc::new(allocator, Link, { .allocator = allocator, .hub = hub, .open = true, .references = 1 });
	link.mutex.init()!!;
	return link;
}

<* Take one more reference, for a handle that the worker has just created. *>
fn void Link.retain(&self)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	self.references++;
}

<* Mark the service closed: from now on releases are refused. Called before the worker stops. *>
fn void Link.shut(&self)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	self.open = false;
}

<* Drop one reference; the link is freed with the last one. *>
fn void Link.drop(&self)
{
	self.mutex.lock()!!;
	self.references--;
	bool last = self.references == 0;
	self.mutex.unlock();
	if (!last) return;
	self.mutex.destroy();
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<*
 Queue `command` for the worker, unless the service is closed. Holds the lock, so
 `Power.close` cannot close the hub between the check and the post.

 @return? error::DISCONNECTED : "The service was closed; the hold or inhibitor went with it"
 @return? error::BUSY : "The worker's queue is full"
*>
fn void? Link.queue(&self, Command command)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	if (!self.open) return error::DISCONNECTED~;
	if (catch err = self.hub.post(command)) return err~;
}

<* The profile hold `cookie` for a request the worker has served; the handle takes its own reference here. *>
fn ProfileHold make_hold(Command* command, uint cookie)
{
	command.link.retain();
	return { .cookie = cookie, .link = command.link };
}

<* The inhibitor `id` for a request the worker has served; the handle takes its own reference here. *>
fn Inhibitor make_inhibitor(Command* command, uint id)
{
	command.link.retain();
	return { .id = id, .link = command.link };
}

<*
 Release the profile hold: the daemon is told to drop it. A refused release leaves the
 hold live, so the caller may try again; once the service is closed the hold is spent.

 @return? error::DISCONNECTED : "The service was closed; the daemon has already dropped the hold"
 @return? error::BUSY : "The worker's queue is full; try again"
*>
fn void? ProfileHold.release(&self)
{
	if (self.link == null) return;
	Link* link = self.link;
	if (catch err = link.queue({ .kind = RELEASE_PROFILE, .number = self.cookie }))
	{
		if (err == error::DISCONNECTED)
		{
			self.link = null;
			link.drop();
		}
		return err~;
	}
	self.link = null;
	link.drop();
}

<*
 Release the inhibitor: its descriptor is closed, which releases the lock. A refused
 release leaves the inhibitor live, so the caller may try again; once the service is
 closed the inhibitor is spent (closing the service released it).

 @return? error::DISCONNECTED : "The service was closed; the inhibitor was released with it"
 @return? error::BUSY : "The worker's queue is full; try again"
*>
fn void? Inhibitor.release(&self)
{
	if (self.link == null) return;
	Link* link = self.link;
	if (catch err = link.queue({ .kind = RELEASE_INHIBITOR, .number = self.id }))
	{
		if (err == error::DISCONNECTED)
		{
			self.link = null;
			link.drop();
		}
		return err~;
	}
	self.link = null;
	link.drop();
}