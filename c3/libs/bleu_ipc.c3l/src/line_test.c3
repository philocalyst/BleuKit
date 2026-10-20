module bleu::ipc::line_test @feat(POSIX);
import bleu::ipc::line, bleu::ipc::wire, bleu::error, std::core::test;

// Hands `text` to the buffer the way socket reads would: each read fills at most
// the room `reserve` gives, and the buffer is then committed.
fn void feed(line::LineBuffer* buffer, String text)
{
	usz offset = 0;
	while (offset < (usz)text.len)
	{
		char[] room = buffer.reserve();
		usz count = min_of((usz)room.len, (usz)text.len - offset);
		mem::copy(room.ptr, &text[(sz)offset], (sz)count);
		buffer.commit(count);
		offset += count;
	}
}

fn usz min_of(usz a, usz b) => a < b ? a : b;

fn void one_line_split_across_reads_comes_out_whole() @test
{
	line::LineBuffer buffer;
	buffer.init(mem, wire::DEFAULT_MAX_LINE);
	defer buffer.free();
	feed(&buffer, "{\"id\":1,\"met");
	test::@error(buffer.next_line(), NO_MORE_ELEMENT);
	feed(&buffer, "hod\":\"ping\"}\n");
	String line = buffer.next_line()!!;
	test::eq(line, "{\"id\":1,\"method\":\"ping\"}");
	test::@error(buffer.next_line(), NO_MORE_ELEMENT);
}

fn void many_lines_in_one_read_come_out_in_order() @test
{
	line::LineBuffer buffer;
	buffer.init(mem, wire::DEFAULT_MAX_LINE);
	defer buffer.free();
	feed(&buffer, "one\ntwo\r\n\nfour\npartial");
	test::eq(buffer.next_line()!!, "one");
	test::eq(buffer.next_line()!!, "two");
	test::eq(buffer.next_line()!!, "");
	test::eq(buffer.next_line()!!, "four");
	test::@error(buffer.next_line(), NO_MORE_ELEMENT);
	feed(&buffer, " tail\n");
	test::eq(buffer.next_line()!!, "partial tail");
}

fn void a_line_longer_than_the_chunk_size_is_reassembled() @test
{
	line::LineBuffer buffer;
	buffer.init(mem, wire::DEFAULT_MAX_LINE);
	defer buffer.free();
	usz size = wire::READ_CHUNK * 3 + 17;
	char[] body = alloc::new_array(mem, char, (sz)size);
	defer alloc::free(mem, body.ptr);
	mem::set(body.ptr, 'x', (sz)size);
	feed(&buffer, (String)body[0 : (sz)size]);
	test::@error(buffer.next_line(), NO_MORE_ELEMENT);
	feed(&buffer, "\n");
	String line = buffer.next_line()!!;
	test::eq(line.len, (sz)size);
}

fn void a_line_of_exactly_the_limit_is_accepted() @test
{
	line::LineBuffer buffer;
	buffer.init(mem, 8);
	defer buffer.free();
	feed(&buffer, "12345678\n");
	test::eq(buffer.next_line()!!, "12345678");
}

fn void a_line_over_the_limit_is_refused_whether_or_not_it_ended() @test
{
	line::LineBuffer growing;
	growing.init(mem, 8);
	defer growing.free();
	feed(&growing, "123456789");
	test::@error(growing.next_line(), error::OUT_OF_RANGE);

	line::LineBuffer terminated;
	terminated.init(mem, 8);
	defer terminated.free();
	feed(&terminated, "123456789\nok\n");
	test::@error(terminated.next_line(), error::OUT_OF_RANGE);
}
