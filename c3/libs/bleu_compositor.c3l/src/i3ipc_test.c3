module bleu::compositor::i3ipc_test @feat(POSIX);
import bleu::compositor::i3ipc, bleu::compositor::wire, bleu::error, std::core::test;

fn void frame_round_trips_in_native_order() @test
{
	char[] frame = i3ipc::encode(mem, (uint)i3ipc::MessageType.GET_TREE, "");
	defer alloc::free(mem, frame.ptr);
	test::eq((sz)14, frame.len);
	i3ipc::Header header = i3ipc::decode_header((String)frame)!!;
	test::eq((uint)4, header.type);
	test::eq((uint)0, header.length);
	test::@check(!header.is_event(), "a request is not an event");
	char[] payload = i3ipc::encode(mem, (uint)i3ipc::MessageType.RUN_COMMAND, "focus");
	defer alloc::free(mem, payload.ptr);
	test::eq((uint)5, i3ipc::decode_header((String)payload)!!.length);
	test::@check((String)payload[14:5] == "focus", "the payload follows the header");
}

fn void event_bit_is_split_from_the_event_type() @test
{
	i3ipc::Header header = { .type = i3ipc::EVENT_BIT | 3, .length = 0 };
	test::@check(header.is_event(), "bit 31 marks an event");
	test::eq((uint)3, header.event_type());
	test::@check(i3ipc::event_name(header.event_type()) == "window", "type 3 is the window event");
	test::@check(i3ipc::event_name(21) == "input", "type 21 is the sway input event");
	test::@check(i3ipc::event_name(99) == "unknown", "an unknown type is named unknown");
}

fn void frames_arrive_in_pieces_and_several_per_read() @test
{
	char[] first = i3ipc::encode(mem, i3ipc::EVENT_BIT | 0, "{\"change\":\"focus\"}");
	defer alloc::free(mem, first.ptr);
	char[] second = i3ipc::encode(mem, i3ipc::EVENT_BIT | 3, "{}");
	defer alloc::free(mem, second.ptr);
	wire::Buffer buffer;
	buffer.init(mem, 256);
	defer buffer.free();
	// Ten bytes of the first frame: no header yet, so nothing can be taken.
	buffer.feed(first[0:10])!!;
	test::@error(i3ipc::take_frame(&buffer), NOT_FOUND);
	// The rest of the first frame and all of the second arrive together.
	char[] rest = first[10:first.len - 10];
	buffer.feed(rest)!!;
	buffer.feed(second)!!;
	i3ipc::Frame one = i3ipc::take_frame(&buffer)!!;
	test::@check(one.payload == "{\"change\":\"focus\"}", "the first payload must come out whole");
	test::@check(one.header.is_event(), "the first frame is an event");
	i3ipc::Frame two = i3ipc::take_frame(&buffer)!!;
	test::eq((uint)3, two.header.event_type());
	test::@error(i3ipc::take_frame(&buffer), NOT_FOUND);
}

fn void bad_magic_is_a_protocol_error() @test
{
	wire::Buffer buffer;
	buffer.init(mem, 64);
	defer buffer.free();
	buffer.feed("i3-xpc\x00\x00\x00\x00\x00\x00\x00\x00")!!;
	test::@error(i3ipc::take_frame(&buffer), error::PROTOCOL);
}

fn void oversized_frame_is_refused_before_it_is_read() @test
{
	char[14] header = { 'i', '3', '-', 'i', 'p', 'c', 0xff, 0xff, 0xff, 0x7f, 0, 0, 0, 0 };
	wire::Buffer buffer;
	buffer.init(mem, 64);
	defer buffer.free();
	buffer.feed(header[..])!!;
	test::@error(i3ipc::take_frame(&buffer), error::PROTOCOL);
}