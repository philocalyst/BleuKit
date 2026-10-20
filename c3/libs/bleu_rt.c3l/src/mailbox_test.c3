module bleu::rt::mailbox_test;
import bleu::rt::mailbox, bleu::error, std::core::test;

fn void mailbox_keeps_order_across_growth() @test
{
	mailbox::Mailbox{int} box;
	box.init(mem, 64)!!;
	defer box.free();
	// More than INITIAL_CAPACITY, so the ring must grow and keep its order.
	for (int i = 0; i < 40; i++) box.post(i)!!;
	test::eq((usz)40, box.pending());
	int[64] buffer;
	usz taken = box.take_all(buffer[..]);
	test::eq((usz)40, taken);
	for (int i = 0; i < 40; i++) test::eq(i, buffer[i]);
	test::eq((usz)0, box.pending());
}

fn void mailbox_refuses_past_its_maximum() @test
{
	mailbox::Mailbox{int} box;
	box.init(mem, 4)!!;
	defer box.free();
	for (int i = 0; i < 4; i++) box.post(i)!!;
	test::@error(box.post(99), error::BUSY);
	// A refused post leaves the queue as it was.
	test::eq((usz)4, box.pending());
}

fn void mailbox_closed_refuses_but_keeps_queued_commands() @test
{
	mailbox::Mailbox{int} box;
	box.init(mem, 8)!!;
	defer box.free();
	box.post(7)!!;
	box.close();
	box.close();
	test::@check(box.is_closed(), "close() must mark the mailbox closed");
	test::@error(box.post(8), error::UNAVAILABLE);
	int[4] buffer;
	test::eq((usz)1, box.take_all(buffer[..]));
	test::eq(7, buffer[0]);
}

fn void mailbox_partial_take_leaves_the_rest_queued() @test
{
	mailbox::Mailbox{int} box;
	box.init(mem, 8)!!;
	defer box.free();
	box.post(1)!!;
	box.post(2)!!;
	box.post(3)!!;
	int[1] buffer;
	test::eq((usz)1, box.take_all(buffer[..]));
	test::eq(1, buffer[0]);
	test::eq((usz)2, box.pending());
	test::eq((usz)1, box.take_all(buffer[..]));
}