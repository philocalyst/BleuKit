<*
 The two seams between the DDC/CI protocol and the outside world: the byte
 channel to one display, and the way the session waits.

 This library does no I/O of its own. A backend implements `Transport` on top
 of `/dev/i2c-N`, `IOI2CSendRequest`, `IOAVServiceWriteI2C` or the dxva2 calls;
 the session drives it. Waiting goes through `Sleeper`, so tests run instantly.
*>
module bleu::ddc::transport;
import std::thread, std::time, bleu::deadline;

<*
 The byte channel to one display's DDC/CI slave, at the 7-bit address 0x37.

 Implementations do all native I/O. The session calls them from one thread at
 a time (the service's worker thread).

 - `write` sends the whole buffer as one transfer. The bytes are the I2C form
 (`packet.Request.encode_i2c`); the destination address is the transfer's
 device address, so it is not in the buffer.
 - `read` fills at most `buffer.len` bytes and returns how many arrived. Zero
 means nothing arrived within `timeout`, which is not an error. A transport
 that cannot do a short read must still return what the device supplied.
 - `min_interval_after_write` is the least time the transport needs between a
 write and the next read. The session waits at least that long. Some AMD
 graphics need about 30 ms more than the specification (Lunar `DDC.c`,
 `DDCDelay`).
*>
interface Transport
{
	fn void? write(char[] bytes);
	fn usz? read(char[] buffer, Duration timeout);
	fn Duration min_interval_after_write();
}

<*
 Suspends the calling thread for at least `duration`. `context` is passed back
 unchanged.
*>
alias SleepFn = fn void(void* context, Duration duration);

<*
 How the session waits. Injected rather than hard-wired so that tests run
 without real delays and a backend can run the waits on its own worker.
*>
struct Sleeper
{
	SleepFn sleep;
	void* context;
}

<*
 The operating system's sleep, in a loop that ends on the monotonic clock. A
 sleep interrupted by a signal returns early, and the loop waits the rest, so
 every delay the DDC/CI timing rules require is honoured in full.
*>
fn Sleeper real_sleeper() => { .sleep = &sleep_at_least, .context = null };

fn void sleep_at_least(void* context, Duration duration) @private
{
	Deadline until = deadline::after(duration);
	while (!until.expired())
	{
		// An interrupted sleep returns early; the loop above waits the rest.
		if (catch thread::sleep(until.remaining()))
		{
		}
	}
}