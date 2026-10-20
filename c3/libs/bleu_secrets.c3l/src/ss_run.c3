<*
 The Secret Service worker loop: wait for commands or bus traffic, run the
 commands, and keep the published state current.

 Commands run one after another, so a prompt holds up the commands behind it.
 Each prompt is bounded by the operation's deadline, and a cancelled
 operation ends its wait at once, so nothing waits forever.
*>
module bleu::secrets::ss @feat(LINUX);
import std::atomic;
import std::time, bleu::error, bleu::rt::poller, bleu::rt::worker, bleu::service, bleu::operation, bleu::secrets;

<* The longest the loop sleeps when neither a command nor bus traffic arrives: 1 s. *>
const Duration IDLE_TIMEOUT = (Duration)1_000_000;
<* Poller tag of the bus connection; the wake-up has its own. *>
const usz BUS_TAG = 1;

// The worker thread: serve commands and bus traffic until the service stops.
fn void run(void* state, KeyringHub* hub, Host{Command}* host)
{
	SsBackend* b = (SsBackend*)state;
	b.hub = hub;
	b.bus.init(b.allocator);
	b.bus_ready = true;
	publish(b);
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 2))
	{
		shutdown(b);
		return;
	}
	defer poller.free();
	Command[8] commands;
	while (!host.stopping())
	{
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++) execute(b, &commands[i]);
		if (b.bus.is_open)
		{
			if (catch err = b.bus.process()) drop(b);
		}
		if (b.lock_dirty)
		{
			b.lock_dirty = false;
			refresh_lock(b);
		}
		wait_for_work(b, &poller);
	}
	shutdown(b);
}

// Release the connection on the worker thread that owns it.
fn void shutdown(SsBackend* b)
{
	drop(b);
	if (b.bus_ready) b.bus.free();
	b.bus_ready = false;
}

// Sleep until a command arrives, the bus has data, or the idle timeout passes.
fn void wait_for_work(SsBackend* b, Poller* poller)
{
	bool watching = false;
	if (b.bus.is_open)
	{
		if (try fd = b.bus.fd())
		{
			watching = true;
			if (catch poller.add({ .handle = (Native)fd, .interest = { .readable = true }, .tag = BUS_TAG })) watching = false;
		}
	}
	if (catch poller.wait(IDLE_TIMEOUT)) {}
	if (watching)
	{
		if (catch poller.remove(BUS_TAG)) {}
	}
}

// Run one command with its temporaries in the pool, then refresh the lock state.
fn void execute(SsBackend* b, Command* command)
{
	@pool()
	{
		switch (command.kind)
		{
			case STORE: run_store(b, command);
			case READ: run_read(b, command);
			case DELETE: run_delete(b, command);
			case SEARCH: run_search(b, command);
			case UNLOCK: run_unlock(b, command);
		}
	};
	if (b.bus.is_open) refresh_lock(b);
}

// A dropped connection forgets the session, so the next command negotiates a new one.
fn void forget_if_disconnected(SsBackend* b, fault err)
{
	if (err == error::DISCONNECTED) drop(b);
}

fn void run_store(SsBackend* b, Command* command)
{
	Operation{Entry}* op = (Operation{Entry}*)command.operation;
	defer op.release();
	Entry? stored = store(b, command.entry, command.value, &op.cancel_flag);
	if (catch err = stored)
	{
		forget_if_disconnected(b, err);
		op.fail(err);
		return;
	}
	op.succeed(stored);
}

fn void run_read(SsBackend* b, Command* command)
{
	Operation{Secret}* op = (Operation{Secret}*)command.operation;
	defer op.release();
	Secret? secret = read_value(b, command.entry, &op.cancel_flag, op.allocator());
	if (catch err = secret)
	{
		forget_if_disconnected(b, err);
		op.fail(err);
		return;
	}
	op.succeed(secret);
}

fn void run_delete(SsBackend* b, Command* command)
{
	Operation{bool}* op = (Operation{bool}*)command.operation;
	defer op.release();
	bool? removed = delete_entry(b, command.entry, &op.cancel_flag);
	if (catch err = removed)
	{
		forget_if_disconnected(b, err);
		op.fail(err);
		return;
	}
	op.succeed(removed);
}

fn void run_search(SsBackend* b, Command* command)
{
	Operation{Entry[]}* op = (Operation{Entry[]}*)command.operation;
	defer op.release();
	Entry[]? found = search_entries(b, command.entry, op.allocator());
	if (catch err = found)
	{
		forget_if_disconnected(b, err);
		op.fail(err);
		return;
	}
	op.succeed(found);
}

fn void run_unlock(SsBackend* b, Command* command)
{
	Operation{Lock}* op = (Operation{Lock}*)command.operation;
	defer op.release();
	Lock? lock = unlock_keyring(b, &op.cancel_flag);
	if (catch err = lock)
	{
		forget_if_disconnected(b, err);
		op.fail(err);
		return;
	}
	op.succeed(lock);
}
