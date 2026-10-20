<*
 The worker loop shared by the backends that call the OS synchronously: the
 Windows Credential Manager and the macOS keychain. There is no session and no
 bus, so the loop only waits for commands and runs them one at a time.
*>
module bleu::secrets;
import std::time, bleu::availability, bleu::observe, bleu::rt::poller, bleu::rt::worker, bleu::service, bleu::stream;

<* Runs one command. The backend completes its operation and releases its reference. *>
alias LocalExecuteFn = fn void(void* state, KeyringHub* hub, Command* command);

<* The longest the loop sleeps without a command: 1 s. *>
const Duration LOCAL_IDLE_TIMEOUT = (Duration)1_000_000;

<*
 Publish the initial state, then serve commands until the service stops. Each
 command runs with its temporaries in the pool.
*>
fn void serve_local(void* state, KeyringHub* hub, Host{Command}* host, LocalExecuteFn execute)
{
	Snapshot{State}* first = hub.begin();
	first.value = { .transport = NONE, .lock = UNKNOWN };
	hub.publish_if_changed(first);
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	Command[8] commands;
	while (!host.stopping())
	{
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++)
		{
			@pool()
			{
				execute(state, hub, &commands[i]);
			};
		}
		if (catch poller.wait(LOCAL_IDLE_TIMEOUT)) {}
	}
}

<* Emit a transient event. Strings are copied into the event packet. *>
fn void emit_local(KeyringHub* hub, EventKind kind, String service, String account)
{
	Packet{Event}* packet = hub.emit_begin();
	packet.value = { .kind = kind, .service = service.copy(packet.allocator()), .account = account.copy(packet.allocator()) };
	hub.emit(packet);
}

<*
 Capabilities of a backend that has no session and no lock: store, read, delete
 and search work; unlock and the encrypted transport do not apply.
*>
fn void local_capabilities(Capabilities* capabilities, String no_unlock, String no_transport)
{
	capabilities.init(availability::YES);
	capabilities.values[Cap.UNLOCK.ordinal] = availability::no(UNSUPPORTED_OS, no_unlock);
	capabilities.values[Cap.ENCRYPTED_TRANSPORT.ordinal] = availability::no(UNSUPPORTED_OS, no_transport);
}
