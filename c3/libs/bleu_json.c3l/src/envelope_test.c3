module bleu::json::envelope;
import bleu::error;
import bleu::json;

<* The text of the most recent error on this thread. *>
fn String last_message() => (String)error::last().text[0:error::last().len];

fn void frames_have_the_documented_shape() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	JsonWriter w;
	w.init_dstring(&out);
	write_result(&w, 1, 3)!!;
	write_error(&w, 2, "no \"battery\"")!!;
	write_event(&w, 3, "battery", "full")!!;
	write_result_raw(&w, 4, ` {"a":[1,2]} `)!!;
	write_event_raw(&w, 5, "network", "[true]")!!;
	assert(out.str_view() == "{\"id\":1,\"result\":3}\n"
		"{\"id\":2,\"error\":\"no \\\"battery\\\"\"}\n"
		"{\"id\":3,\"result\":{\"service\":\"battery\",\"data\":\"full\"}}\n"
		"{\"id\":4,\"result\":{\"a\":[1,2]}}\n"
		"{\"id\":5,\"result\":{\"service\":\"network\",\"data\":[true]}}\n");
}

fn void a_frame_refuses_an_indenting_writer() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	JsonWriter w;
	w.init_dstring(&out, 2);
	if (catch write_result(&w, 1, 3))
	{
		assert(error::last().status == error::Status.INVALID_STATE);
	}
	else
	{
		assert(false);
	}
}

fn void requests_parse_into_their_fields() @test
{
	Request r = parse_request(mem, `{"id":9007199254740992,"method":"battery.get","params":{"step":1}}`)!!;
	assert(r.id == 9007199254740992);
	assert(r.method == "battery.get");
	assert(r.params != null && r.params.is_map());
	r.free();
	Request bare = parse_request(mem, `{"id":2,"method":"ping"}`)!!;
	assert(bare.params == null);
	bare.free();
	Request fractional_id = parse_request(mem, `{"id":3.0,"method":"ping"}`)!!;
	assert(fractional_id.id == 3);
	fractional_id.free();
}

fn void bad_requests_are_refused_with_their_class() @test
{
	if (catch parse_request(mem, "{not json"))
	{
		assert(error::last().status == error::Status.PROTOCOL);
	}
	else
	{
		assert(false);
	}
	if (catch parse_request(mem, "[1]"))
	{
		assert(last_message() == "request is not a JSON object");
	}
	else
	{
		assert(false);
	}
	if (catch parse_request(mem, `{"id":1.5,"method":"x"}`))
	{
		assert(error::last().status == error::Status.INVALID_ARGUMENT);
	}
	else
	{
		assert(false);
	}
	if (catch parse_request(mem, `{"id":9007199254740993,"method":"x"}`))
	{
		assert(error::last().status == error::Status.OUT_OF_RANGE);
	}
	else
	{
		assert(false);
	}
	if (catch parse_request(mem, `{"id":1}`))
	{
		assert(last_message() == "member 'method' is missing or null");
	}
	else
	{
		assert(false);
	}
	if (catch parse_request(mem, `{"id":1,"method":"x","params":[1]}`))
	{
		assert(last_message() == "request params is not an object");
	}
	else
	{
		assert(false);
	}
}

fn void oversized_requests_are_refused_before_parsing() @test
{
	char[] line = alloc::new_array(mem, char, MAX_FRAME + 1);
	defer alloc::free(mem, line);
	mem::set(line.ptr, ' ', line.len);
	if (catch parse_request(mem, (String)line))
	{
		assert(error::last().status == error::Status.OUT_OF_RANGE);
	}
	else
	{
		assert(false);
	}
}
