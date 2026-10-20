// Disconnect test: opens the session bus, reports CONNECTED, and waits. The
// driver (../integration.sh) stops the bus daemon. This program must then report
// DISCONNECTED from process(), an attempt to reopen must fail with UNAVAILABLE,
// and once the driver restarts the bus at the same address, reopening must succeed.
module bleu::dbus::disconnect_test;
import bleu::error, bleu::deadline, bleu::dbus::connection, bleu::dbus::transport;
import std::io, std::time, std::thread;

<* How long the bus may take to notice the driver stopping it, in milliseconds. *>
const WAIT_MS = 20000;

fn int main()
{
	Connection bus;
	bus.init(mem);
	defer bus.free();
	if (catch err = bus.open_session())
	{
		io::printfn("FAIL open_session: %s", err);
		return 1;
	}
	io::printfn("CONNECTED");
	Deadline d = deadline::after(time::ms(WAIT_MS));
	while (!d.expired())
	{
		if (catch err = bus.process())
		{
			io::printfn("DISCONNECTED %s", err);
			break;
		}
		transport::wait(bus.fd() ?? -1, true, false, time::ms(50));
	}
	if (catch err = bus.open_session())
	{
		io::printfn("REOPEN %s", err);
	}
	else
	{
		io::printfn("REOPEN unexpectedly succeeded");
	}
	// The driver restarts the bus at the same address; the same object must reconnect.
	Deadline again = deadline::after(time::ms(WAIT_MS));
	while (!again.expired())
	{
		if (try bus.open_session())
		{
			io::printfn("REOPENED as %s", bus.name_on_bus());
			return 0;
		}
		thread::sleep(time::ms(100))!!;
	}
	io::printfn("REOPENED timed out");
	return 1;
}