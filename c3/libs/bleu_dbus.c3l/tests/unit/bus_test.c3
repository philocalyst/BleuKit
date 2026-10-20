// Unit tests for the reply codes of the bus daemon's own methods. The codes are the
// specification's (Message Bus Specification: RequestName, ReleaseName and
// StartServiceByName); a code outside them is an error, not a value.
module bleu::dbus::bus_test;
import bleu::error, bleu::dbus::bus, bleu::dbus::testing;

fn void name_reply_codes_are_the_specifications() @test
{
	assert(bus::name_reply_of(1)!! == bus::NameReply.PRIMARY_OWNER);
	assert(bus::name_reply_of(2)!! == bus::NameReply.IN_QUEUE);
	assert(bus::name_reply_of(3)!! == bus::NameReply.EXISTS);
	assert(bus::name_reply_of(4)!! == bus::NameReply.ALREADY_OWNER);
	testing::@expect_fault(bus::name_reply_of(0), error::BACKEND_FAILURE);
	testing::@expect_fault(bus::name_reply_of(5), error::BACKEND_FAILURE);
}

fn void release_reply_codes_are_the_specifications() @test
{
	assert(bus::release_reply_of(1)!! == bus::ReleaseReply.RELEASED);
	assert(bus::release_reply_of(2)!! == bus::ReleaseReply.NON_EXISTENT);
	assert(bus::release_reply_of(3)!! == bus::ReleaseReply.NOT_OWNER);
	testing::@expect_fault(bus::release_reply_of(0), error::BACKEND_FAILURE);
	testing::@expect_fault(bus::release_reply_of(4), error::BACKEND_FAILURE);
}

fn void start_reply_codes_are_the_specifications() @test
{
	assert(bus::start_reply_of(1)!! == bus::StartReply.SUCCESS);
	assert(bus::start_reply_of(2)!! == bus::StartReply.ALREADY_RUNNING);
	testing::@expect_fault(bus::start_reply_of(0), error::BACKEND_FAILURE);
	testing::@expect_fault(bus::start_reply_of(3), error::BACKEND_FAILURE);
}
