module bleu::notify::sender_test;
import bleu::availability, bleu::error, bleu::notify, bleu::notify::sender;

// A driver that accepts everything and reports id 7.
fn notify::NoteId? accept(void* state, sender::Request* request)
{
	return 7;
}

sender::SenderDriver fake_driver;

// A sender on the fake driver, with every feature offered.
fn sender::Sender fake_sender()
{
	fake_driver = { .info = { "fake", "test driver", 0 }, .send_fn = &accept };
	sender::Sender s = { .driver = &fake_driver };
	s.features.init(availability::YES);
	return s;
}

fn void a_request_using_a_refused_feature_is_refused() @test
{
	sender::Sender s = fake_sender();
	s.features.set(sender::Feature.ACTIONS, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "none"));
	notify::Action[1] actions = { { .key = "a", .label = "A" } };
	sender::Request request   = sender::new_request("with a button");
	request.actions = actions[:1];
	bool refused = false;
	if (catch err = s.send(request)) refused = err == error::UNSUPPORTED;
	assert(refused);
}

fn void a_plain_request_reaches_the_backend() @test
{
	sender::Sender s = fake_sender();
	s.features.set(sender::Feature.ACTIONS, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "none"));
	assert((s.send(sender::new_request("plain")) ?? 0) == 7);
}

fn void a_refused_feature_is_refused_only_when_used() @test
{
	sender::Sender s = fake_sender();
	s.features.set(sender::Feature.EXPIRY, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "none"));
	// The default request leaves the expiry at -1, the server's own timeout: never refused.
	assert((s.send(sender::new_request("default expiry")) ?? 0) == 7);
	sender::Request timed = sender::new_request("timed");
	timed.expire_ms = 1000;
	bool refused = false;
	if (catch err = s.send(timed)) refused = err == error::UNSUPPORTED;
	assert(refused);
}

fn void new_requests_use_the_server_defaults() @test
{
	sender::Request r = sender::new_request("x");
	assert(r.urgency == notify::Urgency.NORMAL);
	assert(r.expire_ms == -1);
	assert(r.replaces_id == 0);
}