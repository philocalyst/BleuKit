module bleu::stream_test;
import bleu::stream, bleu::error, std::core::test, std::time;

fn void publish_value(stream::Stream{int}* events, int value)
{
	stream::Packet{int}* packet = events.begin();
	packet.value = value;
	events.publish(packet);
}

fn void events_arrive_in_order_for_every_reader() @test
{
	stream::Stream{int} events;
	events.init(mem);
	defer events.destroy();
	stream::Reader{int}* reader = events.subscribe()!!;
	defer reader.release();
	publish_value(&events, 1);
	publish_value(&events, 2);
	stream::Packet{int}* first = reader.next(time::ms(100))!!;
	test::eq(1, first.value);
	first.release();
	stream::Packet{int}* second = reader.next(time::ms(100))!!;
	test::eq(2, second.value);
	second.release();
	test::eq((ulong)0, reader.take_dropped());
}

fn void an_empty_reader_times_out() @test
{
	stream::Stream{int} events;
	events.init(mem);
	defer events.destroy();
	stream::Reader{int}* reader = events.subscribe()!!;
	defer reader.release();
	test::@error(reader.next(time::ms(2)), TIMEOUT);
}

fn void overflow_drops_the_oldest_and_counts_it() @test
{
	stream::Stream{int} events;
	events.init(mem);
	defer events.destroy();
	stream::Reader{int}* reader = events.subscribe(2)!!;
	defer reader.release();
	publish_value(&events, 1);
	publish_value(&events, 2);
	publish_value(&events, 3);
	test::eq((ulong)1, reader.take_dropped());
	test::eq((ulong)0, reader.take_dropped());
	stream::Packet{int}* kept = reader.next(time::ms(100))!!;
	test::eq(2, kept.value);
	kept.release();
	stream::Packet{int}* newest = reader.next(time::ms(100))!!;
	test::eq(3, newest.value);
	newest.release();
}

fn void close_drains_the_queue_then_disconnects() @test
{
	stream::Stream{int} events;
	events.init(mem);
	defer events.destroy();
	stream::Reader{int}* reader = events.subscribe()!!;
	defer reader.release();
	publish_value(&events, 8);
	events.close();
	events.close();
	stream::Packet{int}* left = reader.next(time::ms(100))!!;
	test::eq(8, left.value);
	left.release();
	test::@error(reader.next(time::ms(100)), error::DISCONNECTED);
	test::@error(events.subscribe(), error::DISCONNECTED);
}

fn void publishing_after_close_delivers_nothing() @test
{
	stream::Stream{int} events;
	events.init(mem);
	defer events.destroy();
	stream::Reader{int}* reader = events.subscribe()!!;
	defer reader.release();
	events.close();
	publish_value(&events, 1);
	test::@error(reader.next(time::ms(2)), error::DISCONNECTED);
}

fn void a_reader_released_after_close_is_safe() @test
{
	stream::Stream{int} events;
	events.init(mem);
	defer events.destroy();
	stream::Reader{int}* reader = events.subscribe()!!;
	publish_value(&events, 4);
	events.close();
	reader.release();
}
