// Live integration test, client side of the reverse direction: the existing C3
// client (Proxy, Connection, and the name ownership helpers) calls the C3
// ObjectServer that server_main.c3 runs. Run by ../integration.sh after the Python
// checks, with the server already up. It ends by calling Quit, which makes the
// server give up its name, and prints PASS or FAIL per check; the exit status is
// the number of failures.
module bleu::dbus::server_client_test;
import bleu::error, bleu::deadline, bleu::dbus::bus, bleu::dbus::connection, bleu::dbus::marshal, bleu::dbus::message, bleu::dbus::ownership, bleu::dbus::proxy, bleu::dbus::transport, bleu::dbus::value;
import std::io, std::time;

const SERVICE_NAME   = "org.bleu.ServerTest";
const OBJECT_PATH    = "/org/bleu/ServerTest";
const TEST_INTERFACE = "org.bleu.Test";

// Longest wait for the bus to hand over a name, in milliseconds.
const HANDOVER_WAIT_MS = 2000;

// Longest wait between two polls of the bus, in milliseconds.
const POLL_WAIT_MS = 20;

// Number of failed checks so far.
int failures = 0;

// What the name handlers recorded.
struct NameEvents
{
	bool acquired;
	bool lost;
}

NameEvents events;

fn void check(bool ok, String what)
{
	if (ok)
	{
		io::printfn("PASS %s", what);
		return;
	}
	failures++;
	io::printfn("FAIL %s", what);
}

fn void on_name_acquired(void* context, String name)
{
	events.acquired = true;
}

fn void on_name_lost(void* context, String name)
{
	events.lost = true;
}

// Runs `c` until `done` is set, or until the handover wait passes. False on timeout or failure.
fn bool pump_until(Connection* c, bool* done)
{
	Deadline d = deadline::after(time::ms(HANDOVER_WAIT_MS));
	while (!*done)
	{
		if (catch err = c.process())
		{
			io::printfn("FAIL process %s", err);
			return false;
		}
		if (*done) break;
		if (d.expired()) return false;
		transport::wait(c.fd()!!, true, false, time::ms(POLL_WAIT_MS));
	}
	return true;
}

// Calls `member` of `p` with one string argument, and returns the reply's string.
fn String? call_text(Connection* bus, Proxy* p, String member, String argument, Allocator allocator)
{
	Message* call = p.new_call(tmem, member)!;
	defer call.release();
	call.body_writer("s")!.append_string(argument)!;
	Message* reply = bus.call(call)!;
	defer reply.release();
	return reply.reader()!.read_string()!.copy(allocator);
}

fn int main()
{
	Connection bus;
	bus.init(mem);
	defer bus.free();
	if (catch err = bus.open_session())
	{
		io::printfn("FAIL open %s", err);
		return 1;
	}
	@pool()
	{
		Proxy test = proxy::for_object(&bus, SERVICE_NAME, OBJECT_PATH, TEST_INTERFACE)!!;
		check(
			call_text(&bus, &test, "Echo", "from c3", tmem)!! == "from c3",
			"a C3 client's Echo is answered by the C3 server"
		);

		Message* add = test.new_call(tmem, "Add")!!;
		Writer* w    = add.body_writer("uu")!!;
		w.append_u32(40)!!;
		w.append_u32(2)!!;
		Message* sum = bus.call(add)!!;
		check(sum.reader()!!.read_u32()!! == 42, "Add returns the sum through the proxy");
		sum.release();
		add.release();

		check(test.get_u32("Count")!! == 9, "Count still holds the value the Python client left");
		test.set_property("Count", value::u32(11))!!;
		check(test.get_u32("Count")!! == 11, "a set through Properties.Set is read back");

		if (try label = test.get_string("Label", tmem))
		{
			check(label == "label", "a read-only property is read through Properties.Get");
		}
		else
		{
			check(false, "reading the Label property failed");
		}

		Message* fail = test.new_call(tmem, "Fail")!!;
		if (catch err = bus.call(fail))
		{
			check(err == error::PERMISSION_DENIED, "a failing handler reaches the client as PERMISSION_DENIED");
		}
		else
		{
			check(false, "a failing handler should not succeed");
		}
		fail.release();

		String xml = test.introspect(tmem)!!;
		check(xml.contains("<interface name=\"org.bleu.Test\">"), "the C3 server's introspection names its interface");
	};

	// Name ownership. A refusing request must not queue; a queued one is granted when the owner leaves.
	Connection refuser;
	refuser.init(mem);
	defer refuser.free();
	refuser.open_session()!!;
	if (catch err = refuser.own_name(SERVICE_NAME, bus::NAME_DO_NOT_QUEUE, &on_name_acquired, null, null))
	{
		check(err == error::BUSY, "a request that does not queue is refused with BUSY while the server holds the name");
	}
	else
	{
		check(false, "a second owner was given a name the server holds");
	}

	Connection waiter;
	waiter.init(mem);
	defer waiter.free();
	waiter.open_session()!!;
	OwnedName* queued = waiter.own_name(
		SERVICE_NAME,
		bus::NAME_ALLOW_REPLACEMENT,
		&on_name_acquired,
		&on_name_lost,
		null
	)!!;
	check(!events.acquired, "a queued request waits while the name is owned elsewhere");

	@pool()
	{
		Proxy test     = proxy::for_object(&bus, SERVICE_NAME, OBJECT_PATH, TEST_INTERFACE)!!;
		Message* quit  = test.new_call(tmem, "Quit")!!;
		Message* reply = bus.call(quit)!!;
		check(reply.type == METHOD_RETURN, "Quit is answered before the server exits");
		reply.release();
		quit.release();
	};
	check(pump_until(&waiter, &events.acquired), "the queued request is granted when the server exits");

	// A connection that asks to replace the owner takes the name, and the owner is told it lost it.
	Connection replacer;
	replacer.init(mem);
	defer replacer.free();
	replacer.open_session()!!;
	bus::NameReply answer = replacer.request_name(SERVICE_NAME, bus::NAME_REPLACE_EXISTING)!!;
	check(answer == bus::NameReply.PRIMARY_OWNER, "a request that replaces the owner is granted");
	check(pump_until(&waiter, &events.lost), "the replaced owner is told with NameLost");
	queued.release()!!;

	io::printfn("FAILURES %d", failures);
	return failures;
}