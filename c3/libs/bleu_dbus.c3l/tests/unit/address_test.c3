// Unit tests for bleu::dbus::address: escaping, separators, the unix keys and
// the classes of error. Examples follow the "Server Addresses" section.
module bleu::dbus::address_test;
import bleu::dbus::address, bleu::dbus::testing, bleu::error, std::os::env;

fn void parses_unix_paths_and_lists() @test
{
	@pool()
	{
		Endpoint[] one = address::parse_addresses(tmem, "unix:path=/tmp/dbus-test")!!;
		assert(one.len == 1);
		assert(one[0].path == "/tmp/dbus-test");
		assert(!one[0].abstract);
		Endpoint[] two = address::parse_addresses(tmem, "unix:path=/tmp/a;unix:path=/tmp/b")!!;
		assert(two.len == 2);
		assert(two[1].path == "/tmp/b");
	};
}

fn void parses_abstract_names() @test
{
	@pool()
	{
		Endpoint[] abstract = address::parse_addresses(tmem, "unix:abstract=/tmp/dbus-U8OSdmf7")!!;
		assert(abstract.len == 1);
		assert(abstract[0].abstract);
		assert(abstract[0].path == "/tmp/dbus-U8OSdmf7");
	};
}

fn void unescapes_values() @test
{
	@pool()
	{
		Endpoint[] spaced = address::parse_addresses(tmem, "unix:path=/a%20b")!!;
		assert(spaced[0].path == "/a b");
		Endpoint[] slashed = address::parse_addresses(tmem, "unix:path=/x%2fy")!!;
		assert(slashed[0].path == "/x/y");
	};
}

fn void ignores_guid_and_skips_other_transports() @test
{
	@pool()
	{
		Endpoint[] guid = address::parse_addresses(tmem, "unix:path=/x,guid=00112233445566778899aabbccddeeff")!!;
		assert(guid.len == 1 && guid[0].path == "/x");
		Endpoint[] mixed = address::parse_addresses(tmem, "tcp:host=127.0.0.1,port=4242;unix:path=/tmp/x")!!;
		assert(mixed.len == 1 && mixed[0].path == "/tmp/x");
		testing::@expect_fault(address::parse_addresses(tmem, "tcp:host=127.0.0.1,port=4242"), error::UNSUPPORTED);
	};
}

fn void rejects_malformed_addresses() @test
{
	@pool()
	{
		testing::@expect_fault(address::parse_addresses(tmem, ""), error::INVALID_ARGUMENT);
		testing::@expect_fault(address::parse_addresses(tmem, "unix:dir=/tmp"), error::INVALID_ARGUMENT);
		testing::@expect_fault(address::parse_addresses(tmem, "unix:path=/a%zz"), error::INVALID_ARGUMENT);
		testing::@expect_fault(address::parse_addresses(tmem, "unix:path=/a b"), error::INVALID_ARGUMENT);
		testing::@expect_fault(address::parse_addresses(tmem, "unix:path="), error::INVALID_ARGUMENT);
		testing::@expect_fault(address::parse_addresses(tmem, "unix:path=/a,abstract=/b"), error::INVALID_ARGUMENT);
	};
}

// The specification says a `runtime` address is only listenable: the bus that a connecting
// client uses is the `path` address it names. So `runtime=yes` is not a connect address.
fn void runtime_addresses_are_listen_only() @test
{
	@pool()
	{
		env::set_var("XDG_RUNTIME_DIR", "/run/user/1000", true);
		testing::@expect_fault(address::parse_addresses(tmem, "unix:runtime=yes"), error::INVALID_ARGUMENT);
		testing::@expect_fault(address::parse_addresses(tmem, "unix:runtime=no"), error::INVALID_ARGUMENT);
		Endpoint[] path = address::parse_addresses(tmem, "unix:path=/run/user/1000/bus")!!;
		assert(path[0].path == "/run/user/1000/bus");
	};
}

fn void session_address_honours_the_environment() @test
{
	@pool()
	{
		env::set_var("DBUS_SESSION_BUS_ADDRESS", "unix:path=/tmp/session", true);
		assert(address::session_address(tmem)!! == "unix:path=/tmp/session");
		env::set_var("DBUS_SESSION_BUS_ADDRESS", "autolaunch:", true);
		assert(address::session_address(tmem)!!.starts_with("unix:path=/run/user/"));
		env::set_var("DBUS_SYSTEM_BUS_ADDRESS", "", true);
		assert(address::system_address(tmem) == "unix:path=/var/run/dbus/system_bus_socket");
	};
}