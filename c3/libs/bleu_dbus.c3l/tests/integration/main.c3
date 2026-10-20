// Live integration test: this library against a real dbus-daemon and the python
// mock service (mock_service.py). Run by ../integration.sh, which sets
// DBUS_SESSION_BUS_ADDRESS. Each check prints PASS or FAIL; the exit status is
// the number of failures.
module bleu::dbus::integration_test;
import bleu::error, bleu::deadline, bleu::dbus::connection, bleu::dbus::bus, bleu::dbus::proxy,
	bleu::dbus::match, bleu::dbus::message, bleu::dbus::value, bleu::dbus::marshal,
	bleu::dbus::transport;
import std::io, std::time;

extern fn int pipe(int* fds);
extern fn sz write(int fd, void* buf, usz count);
extern fn int close(int fd);

<* Longest wait for an asynchronous step, in milliseconds. *>
const WAIT_MS = 2000;

<* Number of failed checks so far. *>
int failures = 0;

<* What the handlers of one test recorded. *>
struct Probe
{
	int calls;
	uint number;
	DString text;
	error::Status status;
	String[] strings;
}

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

fn void report(String what, fault err)
{
	failures++;
	io::printfn("FAIL %s: %s (%s)", what, err, error::last().message());
}

// Runs the connection until `probe.calls` reaches `wanted`, or WAIT_MS passes.
fn bool pump_until(Connection* bus, Probe* probe, int wanted)
{
	Deadline d = deadline::after(time::ms(WAIT_MS));
	while (probe.calls < wanted)
	{
		if (catch err = bus.process())
		{
			report("process", err);
			return false;
		}
		if (probe.calls >= wanted) break;
		if (d.expired()) return false;
		transport::wait(bus.fd()!!, true, false, time::ms(20));
	}
	return true;
}

fn void on_text_signal(void* context, Message* signal)
{
	Probe* probe = (Probe*)context;
	probe.calls++;
	if (try r = signal.reader())
	{
		if (try text = r.read_string())
		{
			probe.text.clear();
			probe.text.append_string(text);
		}
	}
}

fn void on_properties(void* context, PropertyChange* change)
{
	Probe* probe = (Probe*)context;
	probe.calls++;
	if (try v = change.changed.dict_get("State"))
	{
		probe.number = v.as_u32() ?? 0;
	}
	probe.strings = change.invalidated;
}

fn void on_objects(void* context, ObjectChange* change)
{
	Probe* probe = (Probe*)context;
	probe.calls++;
	probe.text.clear();
	probe.text.append_string(change.path);
	probe.number = change.added ? 1 : 0;
	probe.strings = change.removed;
}

fn void on_owner(void* context, Message* signal)
{
	Probe* probe = (Probe*)context;
	probe.calls++;
	String name;
	String old_owner;
	String new_owner;
	if (catch err = bus::name_owner_change(signal, &name, &old_owner, &new_owner)) return;
	probe.text.clear();
	probe.text.append_string(new_owner);
}

fn void on_reply(void* context, Message* reply, error::Status status)
{
	Probe* probe = (Probe*)context;
	probe.calls++;
	probe.status = status;
	probe.text.clear();
	if (reply != null)
	{
		if (try text = reply.reader().read_string())
		{
			probe.text.append_string(text);
		}
	}
}

fn int main()
{
	Connection bus;
	bus.init(mem);
	defer bus.free();
	if (catch err = bus.open_session())
	{
		report("open_session", err);
		return 1;
	}
	io::printfn("connected as %s", bus.name_on_bus());
	names_and_owners(&bus);
	Proxy mock = proxy::for_object(&bus, "org.bleu.Mock", "/org/bleu/Mock", "org.bleu.Mock")!!;
	method_calls(&bus, &mock);
	errors_from_the_bus(&bus, &mock);
	properties(&bus, &mock);
	signals(&bus, &mock);
	object_tree(&bus, &mock);
	name_changes(&bus);
	timeouts_and_async(&bus, &mock);
	descriptors(&bus, &mock);
	io::printfn("%d check(s) failed", failures);
	return failures;
}

fn void names_and_owners(Connection* bus)
{
	check(bus.name_on_bus().starts_with(":1."), "Hello gives a unique name");
	@pool()
	{
		String owner = bus.get_name_owner("org.freedesktop.DBus", tmem) ?? "";
		check(owner == "org.freedesktop.DBus", "GetNameOwner of the bus itself");
		String[] names = bus.list_names(tmem) ?? {};
		bool has_mock = false;
		foreach (name : names) has_mock = has_mock || name == "org.bleu.Mock";
		check(has_mock, "ListNames includes the mock service");
		check(bus.name_has_owner("org.bleu.Mock") ?? false, "NameHasOwner is true for the mock");
		check(!(bus.name_has_owner("org.bleu.Nowhere") ?? true), "NameHasOwner is false for an unowned name");
		check(bus.owner_of("org.bleu.Nowhere").len == 0, "owner cache is empty for an untracked name");
	};
}

fn void method_calls(Connection* bus, Proxy* mock)
{
	@pool()
	{
		Message* call = mock.new_call(tmem, "Echo")!!;
		call.body_writer("s")!!.append_string("hello")!!;
		Message* reply = bus.call(call)!!;
		check(reply.reader()!!.read_string() == "hello", "Echo returns its argument");
		reply.release();
	};
	@pool()
	{
		Message* call = mock.new_call(tmem, "Add")!!;
		Writer* w = call.body_writer("ii")!!;
		w.append_i32(2)!!;
		w.append_i32(3)!!;
		Message* reply = bus.call(call)!!;
		check(reply.reader()!!.read_i32()!! == 5, "Add returns the sum");
		reply.release();
	};
	@pool()
	{
		Message* call = mock.new_call(tmem, "Describe")!!;
		Message* reply = bus.call(call)!!;
		Value dict = reply.reader()!!.read_value(tmem)!!;
		check(dict.dict_get("name")!!.as_string()!! == "bleu", "a{sv} reply: plain variant");
		Value nested = dict.dict_get("nested")!!;
		check(nested.dict_get("depth")!!.as_u32()!! == 2, "a{sv} reply: nested a{sv} inside a variant");
		check(nested.dict_get("list")!!.at(1)!!.as_string()!! == "b", "a{sv} reply: array inside a variant");
		check(dict.dict_get("pi")!!.as_f64()!! == 3.5, "a{sv} reply: double inside a variant");
		reply.release();
	};
}

fn void errors_from_the_bus(Connection* bus, Proxy* mock)
{
	@pool()
	{
		Message* call = mock.new_call(tmem, "Fail")!!;
		if (catch err = bus.call(call))
		{
			check(err == error::BACKEND_FAILURE, "an unmapped error name is BACKEND_FAILURE");
			check(error::last().domain == error::Domain.DBUS, "the error is recorded in domain DBUS");
			check(error::last().message().contains("org.bleu.Mock.Error.Boom"), "the D-Bus error name is kept");
		}
		else
		{
			check(false, "Fail must return an error reply");
		}
		call.release();
	};
	@pool()
	{
		Message* call = mock.new_call(tmem, "NoSuchMethod")!!;
		if (catch err = bus.call(call))
		{
			check(err == NOT_FOUND, "UnknownMethod maps to NOT_FOUND");
		}
		else
		{
			check(false, "an unknown method must return an error reply");
		}
		call.release();
	};
	@pool()
	{
		Message* call = message::method_call(tmem, "org.bleu.Nowhere", "/x", "org.bleu.X", "M")!!;
		if (catch err = bus.call(call))
		{
			check(err == error::UNAVAILABLE, "ServiceUnknown maps to UNAVAILABLE");
		}
		else
		{
			check(false, "a call to an absent service must fail");
		}
		call.release();
	};
}

fn void properties(Connection* bus, Proxy* mock)
{
	@pool()
	{
		check((mock.get_u32("State") ?? 0) == 7, "Get a property");
		mock.set_property("State", value::u32(9))!!;
		check((mock.get_u32("State") ?? 0) == 9, "Set a property, then Get it");
		Value all = mock.get_all_properties(tmem)!!;
		check(all.dict_get("Label")!!.as_string()!! == "read only", "GetAll returns every property");
		String xml = mock.introspect(tmem)!!;
		check(xml.contains("org.bleu.Mock") && xml.contains("<node"), "Introspect returns XML");
		Value objects = mock.get_managed_objects(tmem)!!;
		Value item = objects.dict_get("/org/bleu/Mock/item1")!!;
		check(item.dict_get("org.bleu.Mock.Item")!!.dict_get("Size")!!.as_u32()!! == 11,
			"GetManagedObjects returns the object tree");
	};
}

fn void signals(Connection* bus, Proxy* mock)
{
	Probe changes;
	changes.text.init(mem);
	Probe pings;
	pings.text.init(mem);
	defer changes.text.free();
	defer pings.text.free();

	SubscriptionId props = mock.watch_properties(&on_properties, &changes)!!;
	match::Match rule;
	rule.init(mem);
	rule.with_type(MessageType.SIGNAL)!!;
	rule.with_interface("org.bleu.Mock")!!;
	rule.with_member("Ping")!!;
	SubscriptionId ping_id = bus.subscribe(rule, &on_text_signal, &pings)!!;

	@pool()
	{
		Message* call = mock.new_call(tmem, "Touch")!!;
		bus.call(call)!!.release();
		call.release();
	};
	check(pump_until(bus, &changes, 1), "PropertiesChanged is delivered after process()");
	check(changes.number == 9, "PropertiesChanged carries the new value");
	check(pings.calls == 1 && pings.text.str_view() == "touched", "a subscribed signal reaches its handler");

	bus.unsubscribe(ping_id)!!;
	@pool()
	{
		Message* call = mock.new_call(tmem, "Touch")!!;
		bus.call(call)!!.release();
		call.release();
	};
	int before = pings.calls;
	check(pump_until(bus, &changes, 2), "PropertiesChanged still arrives after unsubscribing Ping");
	bus.process() ?? {};
	check(pings.calls == before, "an unsubscribed rule receives nothing");
	mock.watch_properties(&on_properties, &changes) ?? 0;
	bus.unsubscribe(props)!!;
}

fn void object_tree(Connection* bus, Proxy* mock)
{
	Probe probe;
	probe.text.init(mem);
	defer probe.text.free();
	SubscriptionId id = mock.watch_objects(&on_objects, &probe)!!;
	@pool()
	{
		Message* call = mock.new_call(tmem, "AddItem")!!;
		call.body_writer("su")!!.append_string("item3")!!;
		Writer* w = call.body_writer("su")!!;
		w.append_string("item3")!!;
		w.append_u32(33)!!;
		bus.call(call)!!.release();
		call.release();
	};
	check(pump_until(bus, &probe, 1), "InterfacesAdded is delivered");
	check(probe.text.str_view() == "/org/bleu/Mock/item3" && probe.number == 1, "InterfacesAdded names the new object");
	@pool()
	{
		Message* call = mock.new_call(tmem, "RemoveItem")!!;
		call.body_writer("s")!!.append_string("item3")!!;
		bus.call(call)!!.release();
		call.release();
	};
	check(pump_until(bus, &probe, 2), "InterfacesRemoved is delivered");
	check(probe.number == 0 && probe.strings.len == 1, "InterfacesRemoved lists the removed interfaces");
	bus.unsubscribe(id)!!;
}

fn void name_changes(Connection* bus)
{
	Probe probe;
	probe.text.init(mem);
	defer probe.text.free();
	SubscriptionId id = bus.watch_name("org.bleu.Temp", &on_owner, &probe)!!;
	NameReply got = bus.request_name("org.bleu.Temp", 0)!!;
	check(got == NameReply.PRIMARY_OWNER, "RequestName gives primary ownership");
	check(pump_until(bus, &probe, 1), "NameOwnerChanged is delivered for our own name");
	check(probe.text.str_view() == bus.name_on_bus(), "NameOwnerChanged names the new owner");
	ReleaseReply released = bus.release_name("org.bleu.Temp")!!;
	check(released == ReleaseReply.RELEASED, "ReleaseName releases an owned name");
	check(pump_until(bus, &probe, 2), "NameOwnerChanged is delivered when the name is released");
	check(probe.text.len() == 0, "the released name has no owner");
	check(bus.owner_of("org.bleu.Temp").len == 0, "the owner cache follows the release");
	bus.unsubscribe(id)!!;
	check(bus.release_name("org.bleu.Temp")!! == ReleaseReply.NON_EXISTENT, "releasing an unowned name reports NON_EXISTENT");
}

fn void timeouts_and_async(Connection* bus, Proxy* mock)
{
	@pool()
	{
		Message* call = mock.new_call(tmem, "Slow")!!;
		if (catch err = bus.call(call, time::ms(300)))
		{
			check(err == TIMEOUT, "a call past its timeout fails with TIMEOUT");
		}
		else
		{
			check(false, "Slow must not answer within 300 ms");
		}
		call.release();
		check(bus.fd() case INVALID_STATE == false, "the connection stays open after a timeout");
	};
	Probe probe;
	probe.text.init(mem);
	defer probe.text.free();
	@pool()
	{
		Message* call = mock.new_call(tmem, "Echo")!!;
		call.body_writer("s")!!.append_string("async")!!;
		bus.call_async(call, &on_reply, &probe)!!;
		call.release();
	};
	check(pump_until(bus, &probe, 1), "call_async completes through process()");
	check(probe.status == error::Status.OK && probe.text.str_view() == "async", "call_async delivers the reply");
	// The late reply to the timed-out call arrives during this wait; it must be dropped quietly.
	Probe late;
	late.text.init(mem);
	defer late.text.free();
	pump_until(bus, &late, 1);
}

fn void descriptors(Connection* bus, Proxy* mock)
{
	check(bus.fds_negotiated, "unix fd passing was negotiated");
	int[2] fds;
	check(pipe(&fds[0]) == 0, "pipe for the descriptor test");
	write(fds[1], "fd-data", 7);
	close(fds[1]);
	@pool()
	{
		Message* call = mock.new_call(tmem, "ReadFd")!!;
		Writer* w = call.body_writer("h")!!;
		uint index = call.attach_fd(fds[0]);
		w.append_unix_fd(index)!!;
		Message* reply = bus.call(call)!!;
		check(reply.reader()!!.read_string() == "fd-data", "a descriptor sent with a call arrives intact");
		reply.release();
		call.release();
	};
	close(fds[0]);
}
