module bleu::ipc::outbox_test @feat(POSIX);
import bleu::ipc::outbox, bleu::error, std::core::test;

// A heap copy of `text`: the outbox takes ownership of frame bytes.
fn String frame_of(String text)
{
	return text.copy(mem);
}

fn void state_frames_for_one_key_coalesce_to_the_latest() @test
{
	outbox::Outbox box;
	box.init(mem, 1024);
	defer box.free();
	box.put(frame_of("v1\n"), 7, 2)!!;
	box.put(frame_of("v2\n"), 7, 2)!!;
	box.put(frame_of("v3\n"), 7, 2)!!;
	test::eq(box.pending, (usz)3);
	test::eq(box.front().bytes, "v3\n");
	box.advance(3);
	test::@check(box.is_empty());
	test::eq(box.pending, (usz)0);
}

// A replaced frame keeps its place in the queue: the newest value of a key
// takes the slot the key already had.
fn void coalescing_is_per_subscription_and_per_key() @test
{
	outbox::Outbox box;
	box.init(mem, 1024);
	defer box.free();
	box.put(frame_of("a\n"), 7, 2)!!;
	box.put(frame_of("b\n"), 8, 2)!!;
	box.put(frame_of("c\n"), 7, 3)!!;
	box.put(frame_of("d\n"), 7, 2)!!;
	test::eq(box.pending, (usz)6);
	test::eq(box.front().bytes, "d\n");
	box.advance(2);
	test::eq(box.front().bytes, "b\n");
	box.advance(2);
	test::eq(box.front().bytes, "c\n");
	box.advance(2);
	test::@check(box.is_empty());
}

fn void events_with_no_key_are_never_replaced() @test
{
	outbox::Outbox box;
	box.init(mem, 1024);
	defer box.free();
	box.put(frame_of("e1\n"), 7, outbox::NO_KEY)!!;
	box.put(frame_of("e2\n"), 7, outbox::NO_KEY)!!;
	test::eq(box.pending, (usz)6);
	box.advance(3);
	test::eq(box.front().bytes, "e2\n");
	box.advance(3);
	test::@check(box.is_empty());
}

// The socket has taken one byte of "old"; the bytes on the wire cannot be taken
// back, so the newer value is queued behind it.
fn void a_frame_already_on_the_wire_is_not_replaced() @test
{
	outbox::Outbox box;
	box.init(mem, 1024);
	defer box.free();
	box.put(frame_of("old\n"), 7, 2)!!;
	box.advance(1);
	box.put(frame_of("new\n"), 7, 2)!!;
	test::eq(box.pending, (usz)7);
	test::eq(box.front().bytes, "old\n");
	box.advance(3);
	test::eq(box.front().bytes, "new\n");
}

fn void the_byte_bound_refuses_a_frame_past_the_limit() @test
{
	outbox::Outbox box;
	box.init(mem, 10);
	defer box.free();
	box.put(frame_of("123456\n"), 1, outbox::NO_KEY)!!;
	test::@error(box.put(frame_of("abcdefg\n"), 1, outbox::NO_KEY), error::OUT_OF_RANGE);
	test::eq(box.pending, (usz)7);
}

fn void a_single_frame_is_accepted_into_an_empty_queue_whatever_its_size() @test
{
	outbox::Outbox box;
	box.init(mem, 4);
	defer box.free();
	String big = "much longer than four bytes\n";
	box.put(frame_of(big), 1, outbox::NO_KEY)!!;
	test::eq(box.pending, (usz)big.len);
}
