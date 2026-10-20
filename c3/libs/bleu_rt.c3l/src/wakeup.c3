<*
 A cross-thread, level-triggered, coalescing wake-up.

 Any thread calls `signal()`; the thread that owns the wake-up waits for
 `native()` to become readable in a poller, then calls `drain()`. Signals
 coalesce: any number of `signal()` calls before a `drain()` look like one.
 Level-triggered means the wake-up stays readable until drained, so a signal
 raised while the owner is busy is never lost.

 Backends (chosen by `@feat`, see the sibling files):
   Linux    eventfd(2) with EFD_CLOEXEC | EFD_NONBLOCK; one descriptor
   other POSIX  non-blocking, close-on-exec pipe; signal writes one byte
   Windows  a manual-reset event; signal is SetEvent, drain is ResetEvent

 `signal()` never blocks and never allocates, so it may be called from a
 signal handler or a foreign callback. A wake-up is not copyable: two values
 must not close the same descriptor.
*>
module bleu::rt::wakeup;
import bleu::error, bleu::rt;

<*
 A wake-up object. Create it with `init`, and destroy it with `close`.

 @param read_end : "The handle a poller waits on (see `native`)"
 @param write_end : "The handle `signal` writes to: the same as `read_end` on eventfd and Windows"
 @param is_open : "True between `init` and `close`"
*>
struct Wakeup
{
	Native read_end;
	Native write_end;
	bool is_open;
}

<*
 Create the wake-up, initially not signalled.

 @require !self.is_open : "The wake-up is already open"
 @return? error::BACKEND_FAILURE, error::UNSUPPORTED : "The OS refused to create the object"
*>
fn void? Wakeup.init(&self)
{
	native_open(self)?;
	self.is_open = true;
}

<*
 Destroy the wake-up. Safe to call twice; a closed wake-up is simply not open.
*>
fn void Wakeup.close(&self)
{
	if (!self.is_open) return;
	native_close(self);
	self.is_open = false;
}

<*
 Make `native()` readable. Idempotent, non-blocking and async-signal-safe: a
 wake-up that is already pending stays pending and reports success.

 @require self.is_open : "The wake-up must be open"
 @return? error::BACKEND_FAILURE : "The OS rejected the signal"
*>
fn void? Wakeup.signal(&self) @inline
{
	native_signal(self)?;
}

<*
 Clear the pending signal. Call it from the owning thread after `native()` was
 reported readable. Signals raised after `drain` returns are seen by the next wait.

 @require self.is_open : "The wake-up must be open"
 @return? error::BACKEND_FAILURE : "The OS rejected the drain"
*>
fn void? Wakeup.drain(&self) @inline
{
	native_drain(self)?;
}

<*
 The handle a poller waits on.

 @require self.is_open : "The wake-up must be open"
*>
fn Native Wakeup.native(&self) @inline => self.read_end;
