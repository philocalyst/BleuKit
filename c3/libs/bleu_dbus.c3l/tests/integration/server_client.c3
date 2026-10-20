// Live integration test, client side of the reverse direction: the existing C3
// client (Proxy, Connection, own_name's refusal) calls the C3 ObjectServer that
// server_main.c3 runs. Run by ../integration.sh after the Python checks, with the
// server already up. It ends by calling Quit, and prints PASS or FAIL per check;
// the exit status is the number of failures.
module bleu::dbus::server_client_test;
import bleu::error, bleu::dbus::bus, bleu::dbus::connection, bleu::dbus::marshal, bleu::dbus::message, bleu::dbus::ownership, bleu::dbus::proxy, bleu::dbus::value;
import std::io;

const SERVICE_NAME = "org.bleu.ServerTest";
const OBJECT_PATH = "/org/bleu/ServerTest";
const TEST_INTERFACE = "org.bleu.Test";

// Number of failed checks so far.
int failures = 0;

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

// Calls `member` of `p` with `sig` and `body` written by `write`, and returns the reply's first string.
fn String? call_text(Connection* bus, Proxy* p, String member, String sig, String argument, Allocator allocator)
{
	Message* call = p.new_call(tmem, member)!;
	defer call.release();
	call.body_writer(sig)!.append_string(argument)!;
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
		check(call_text(&bus, &test, "Echo", "s", "from c3", tmem)!! == "from c3", "a C3 client's Echo is answered by the C3 server");

		Message* add = test.new_call(tmem, "Add")!!;
		Writer* w = add.body_writer("uu")!!;
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

	Connection other;
	other.init(mem);
	defer other.free();
	other.open_session()!!;
	if (catch err = other.own_name(SERVICE_NAME, bus::NAME_DO_NOT_QUEUE, &refused, null, null))
	{
		check(err == error::BUSY, "a second owner that does not queue is refused with BUSY");
	}
	else
	{
		check(false, "a second owner was given a name the server holds");
	}

	@pool()
	{
		Proxy test = proxy::for_object(&bus, SERVICE_NAME, OBJECT_PATH, TEST_INTERFACE)!!;
		Message* quit = test.new_call(tmem, "Quit")!!;
		Message* reply = bus.call(quit)!!;
		check(reply.type == METHOD_RETURN, "Quit is answered before the server exits");
		reply.release();
		quit.release();
	};
	io::printfn("FAILURES %d", failures);
	return failures;
}

fn void refused(void* context, String name)
{
	io::printfn("FAIL %s was granted to a second owner", name);
}
