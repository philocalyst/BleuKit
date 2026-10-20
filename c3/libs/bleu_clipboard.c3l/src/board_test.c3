module bleu::clipboard;
import std::core::test, std::core::mem;

const usz TEST_PAYLOAD = 1024;

// Offer `mimes` on `slot`, read `text` as its text type, and return the sequence number.
fn ulong copy_text(Board* board, Slot slot, String[] mimes, String text)
{
	ulong seq = board.replace(slot, mimes, false);
	board.captured(slot, seq, "text/plain;charset=utf-8", (char[])text);
	return seq;
}

fn void empty_board_publishes_nothing() @test
{
	Board board;
	board.init(mem, DEFAULT_HISTORY_ITEMS, DEFAULT_HISTORY_BYTES, TEST_PAYLOAD);
	defer board.free();
	State state;
	@pool()
	{
		board.build(tmem, &state);
		test::@check(!state.current.present);
		test::@check(!state.primary.present);
		test::eq(state.history.len, (sz)0);
	};
}

fn void copied_text_is_previewed_and_kept_in_history() @test
{
	Board board;
	board.init(mem, DEFAULT_HISTORY_ITEMS, DEFAULT_HISTORY_BYTES, TEST_PAYLOAD);
	defer board.free();
	ulong seq = copy_text(&board, Slot.CLIPBOARD, { "text/plain;charset=utf-8" }, "hello");
	State state;
	@pool()
	{
		board.build(tmem, &state);
		test::eq(state.current.seq, seq);
		test::eq(state.current.preview, "hello");
		test::eq(state.current.size, (usz)5);
		test::eq(state.history.len, (sz)1);
		test::eq(state.history[0].id, seq);
		test::eq(state.history[0].preview, "hello");
	};
}

fn void concealed_copies_are_neither_read_nor_kept() @test
{
	Board board;
	board.init(mem, DEFAULT_HISTORY_ITEMS, DEFAULT_HISTORY_BYTES, TEST_PAYLOAD);
	defer board.free();
	ulong seq = board.replace(Slot.CLIPBOARD, { "text/plain", MARKER_KDE_PASSWORD_HINT }, false);
	test::@check(!board.text_to_read(Slot.CLIPBOARD).has_value);
	board.captured(Slot.CLIPBOARD, seq, "text/plain", "hunter2");
	State state;
	@pool()
	{
		board.build(tmem, &state);
		test::eq(state.current.privacy, Privacy.CONCEALED);
		test::eq(state.current.preview, "");
		test::eq(state.history.len, (sz)0);
	};
}

fn void a_stale_capture_is_ignored() @test
{
	Board board;
	board.init(mem, DEFAULT_HISTORY_ITEMS, DEFAULT_HISTORY_BYTES, TEST_PAYLOAD);
	defer board.free();
	ulong old = board.replace(Slot.CLIPBOARD, { "text/plain" }, false);
	board.replace(Slot.CLIPBOARD, { "text/plain" }, false);
	board.captured(Slot.CLIPBOARD, old, "text/plain", "late");
	State state;
	@pool()
	{
		board.build(tmem, &state);
		test::eq(state.current.preview, "");
		test::eq(state.history.len, (sz)0);
	};
}

fn void an_oversized_payload_is_not_read_into_the_board() @test
{
	Board board;
	board.init(mem, DEFAULT_HISTORY_ITEMS, DEFAULT_HISTORY_BYTES, TEST_PAYLOAD);
	defer board.free();
	char[] big = alloc::alloc_array(mem, char, TEST_PAYLOAD + 1);
	defer alloc::free(mem, big.ptr);
	mem::set(big.ptr, 'x', big.len);
	ulong seq = board.replace(Slot.CLIPBOARD, { "text/plain" }, false);
	board.captured(Slot.CLIPBOARD, seq, "text/plain", big);
	test::eq(board.lane(Slot.CLIPBOARD).size, (usz)0);
	test::eq(board.items.len(), (sz)0);
}

fn void history_is_bounded_by_count_oldest_first() @test
{
	Board board;
	board.init(mem, 2, DEFAULT_HISTORY_BYTES, TEST_PAYLOAD);
	defer board.free();
	ulong first = copy_text(&board, Slot.CLIPBOARD, { "text/plain" }, "one");
	copy_text(&board, Slot.CLIPBOARD, { "text/plain" }, "two");
	copy_text(&board, Slot.CLIPBOARD, { "text/plain" }, "three");
	test::eq(board.items.len(), (sz)2);
	test::@check(board.find(first) == null);
}

fn void history_is_bounded_by_bytes() @test
{
	Board board;
	board.init(mem, DEFAULT_HISTORY_ITEMS, 10, TEST_PAYLOAD);
	defer board.free();
	ulong first = copy_text(&board, Slot.CLIPBOARD, { "text/plain" }, "aaaaaa");
	copy_text(&board, Slot.CLIPBOARD, { "text/plain" }, "bbbbbb");
	test::eq(board.total_bytes, (usz)6);
	test::@check(board.find(first) == null);
}

fn void an_identical_copy_moves_to_the_top() @test
{
	Board board;
	board.init(mem, DEFAULT_HISTORY_ITEMS, DEFAULT_HISTORY_BYTES, TEST_PAYLOAD);
	defer board.free();
	ulong first = copy_text(&board, Slot.CLIPBOARD, { "text/plain" }, "same");
	copy_text(&board, Slot.CLIPBOARD, { "text/plain" }, "other");
	ulong again = copy_text(&board, Slot.CLIPBOARD, { "text/plain" }, "same");
	test::eq(board.items.len(), (sz)2);
	test::@check(board.find(first) == null);
	test::@check(board.find(again) != null);
}

fn void primary_is_previewed_but_not_kept() @test
{
	Board board;
	board.init(mem, DEFAULT_HISTORY_ITEMS, DEFAULT_HISTORY_BYTES, TEST_PAYLOAD);
	defer board.free();
	copy_text(&board, Slot.PRIMARY, { "text/plain" }, "selected");
	test::eq(board.items.len(), (sz)0);
	test::eq(board.lane(Slot.PRIMARY).preview, "selected");
}

fn void delete_removes_one_entry_once() @test
{
	Board board;
	board.init(mem, DEFAULT_HISTORY_ITEMS, DEFAULT_HISTORY_BYTES, TEST_PAYLOAD);
	defer board.free();
	ulong seq = copy_text(&board, Slot.CLIPBOARD, { "text/plain" }, "gone");
	test::@check(board.delete(seq));
	test::@check(!board.delete(seq));
	test::eq(board.total_bytes, (usz)0);
}

fn void clear_empties_the_selection_and_moves_its_sequence() @test
{
	Board board;
	board.init(mem, DEFAULT_HISTORY_ITEMS, DEFAULT_HISTORY_BYTES, TEST_PAYLOAD);
	defer board.free();
	ulong seq = copy_text(&board, Slot.CLIPBOARD, { "text/plain" }, "x");
	board.clear(Slot.CLIPBOARD);
	test::@check(!board.lane(Slot.CLIPBOARD).present);
	test::@check(board.lane(Slot.CLIPBOARD).seq > seq);
}
