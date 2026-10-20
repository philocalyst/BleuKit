module bleu::notify::store_test;
import std::time, std::collections::maybe, bleu::notify, bleu::notify::store;

// A new entry carrying `summary`, ready to post. Its strings live in the entry's arena.
fn store::Entry* make_entry(
	store::Store* s,
	String summary,
	notify::Urgency urgency = notify::Urgency.NORMAL,
	int expire_ms = -1,
	String sender = ""
)
{
	store::Entry* e = s.new_entry(sender);
	Allocator a     = (Allocator)&e.arena;
	e.incoming.app_name = "test".copy(a);
	e.incoming.summary = summary.copy(a);
	e.incoming.body = "".copy(a);
	e.incoming.expire_ms = expire_ms;
	e.incoming.hints.urgency = urgency;
	return e;
}

fn void ids_follow_the_order_of_arrival() @test
{
	store::Store s;
	s.init(mem, notify::DEFAULT_POLICY);
	defer s.free();
	store::Posted first  = s.post(make_entry(&s, "one"), (Time)1000);
	store::Posted second = s.post(make_entry(&s, "two"), (Time)1000);
	assert(first.id == 1 && second.id == 2);
	assert(s.received == 2);
	assert(s.active.get(0).note.summary == "two");
	assert(s.active.get(1).note.summary == "one");
}

fn void replacing_keeps_the_id_and_the_place() @test
{
	store::Store s;
	s.init(mem, notify::DEFAULT_POLICY);
	defer s.free();
	store::Posted first = s.post(make_entry(&s, "a"), (Time)1000);
	store::Entry* again = make_entry(&s, "b");
	again.incoming.replaces_id = first.id;
	store::Posted second = s.post(again, (Time)2000);
	assert(second.id == first.id && second.replaced);
	assert(s.active.len() == 1);
	assert(s.active.get(0).note.summary == "b");
}

// Regression (N-01): an id that names no open notification is never adopted; the next id is fresh and distinct.
fn void an_unknown_replaces_id_gets_a_fresh_id() @test
{
	store::Store s;
	s.init(mem, notify::DEFAULT_POLICY);
	defer s.free();
	store::Entry* e = make_entry(&s, "x");
	e.incoming.replaces_id = 77;
	store::Posted posted = s.post(e, (Time)1000);
	assert(posted.id != 77 && !posted.replaced);
	assert(s.open(77) == null);
	store::Posted next = s.post(make_entry(&s, "y"), (Time)1000);
	assert(next.id != posted.id, "two open notifications never share an id");
	assert(s.open(posted.id) != null && s.open(next.id) != null);
}

// Regression (N-01): the counter skips ids that are still in history.
fn void a_fresh_id_skips_ids_in_history() @test
{
	store::Store s;
	s.init(mem, notify::DEFAULT_POLICY);
	defer s.free();
	store::Posted first = s.post(make_entry(&s, "a"), (Time)1000);
	assert(s.close(first.id));
	s.last_id = first.id - 1;
	store::Posted again = s.post(make_entry(&s, "b"), (Time)1000);
	assert(again.id != first.id, "a historic id is not issued again");
}

// Regression (N-02): another sender's notification is not replaced, even by its id.
fn void a_replacement_from_another_sender_is_a_new_notification() @test
{
	store::Store s;
	s.init(mem, notify::DEFAULT_POLICY);
	defer s.free();
	store::Posted bank = s.post(make_entry(&s, "password reset", notify::Urgency.NORMAL, -1, "bank"), (Time)1000);
	store::Entry* evil = make_entry(&s, "overwritten", notify::Urgency.NORMAL, -1, "evil");
	evil.incoming.replaces_id = bank.id;
	store::Posted posted = s.post(evil, (Time)1000);
	assert(!posted.replaced && posted.id != bank.id);
	assert(s.active.len() == 2);
	assert(s.open(bank.id).note.summary == "password reset", "the bank's text is untouched");
}

// Regression (N-02): a stack tag matches only the sender that set it.
fn void a_stack_tag_is_matched_within_one_sender() @test
{
	store::Store s;
	s.init(mem, notify::DEFAULT_POLICY);
	defer s.free();
	store::Entry* first = make_entry(&s, "mine", notify::Urgency.NORMAL, -1, "a");
	first.incoming.hints.stack_tag = "chat".copy((Allocator)&first.arena);
	s.post(first, (Time)1000);
	store::Entry* other = make_entry(&s, "theirs", notify::Urgency.NORMAL, -1, "b");
	other.incoming.hints.stack_tag = "chat".copy((Allocator)&other.arena);
	store::Posted posted = s.post(other, (Time)1000);
	assert(!posted.replaced && s.active.len() == 2);
}

// Regression (N-02): a replacement cannot downgrade a critical notification or give it an expiry.
fn void a_replacement_cannot_downgrade_a_critical_notification() @test
{
	store::Store s;
	s.init(mem, notify::DEFAULT_POLICY);
	defer s.free();
	store::Entry* alert = make_entry(&s, "alert", notify::Urgency.CRITICAL, -1, "bank");
	store::Posted first = s.post(alert, (Time)1000);
	store::Entry* quiet = make_entry(&s, "later", notify::Urgency.LOW, 1000, "bank");
	quiet.incoming.replaces_id = first.id;
	store::Posted again = s.post(quiet, (Time)1000);
	assert(again.id == first.id && again.replaced);
	assert(s.open(first.id).note.urgency == notify::Urgency.CRITICAL);
	assert(!again.timeout.has_value, "a critical notification still never expires");
}

// Regression (N-02): a CloseNotification from another sender finds nothing, and the owner's close works.
fn void only_the_owner_closes_by_bus_call() @test
{
	store::Store s;
	s.init(mem, notify::DEFAULT_POLICY);
	defer s.free();
	store::Posted mine = s.post(make_entry(&s, "mine", notify::Urgency.NORMAL, -1, "a"), (Time)1000);
	assert(!s.close_owned(mine.id, "b"), "another sender cannot close it");
	assert(s.open(mine.id) != null);
	assert(s.close_owned(mine.id, "a"), "the sender can");
}

// Regression (N-06): a foreign replacement naming a history entry leaves that entry alone.
fn void a_foreign_replacement_leaves_history_alone() @test
{
	store::Store s;
	s.init(mem, notify::DEFAULT_POLICY);
	defer s.free();
	store::Posted secret = s.post(make_entry(&s, "secret", notify::Urgency.NORMAL, -1, "a"), (Time)1000);
	assert(s.close(secret.id));
	store::Entry* intruder = make_entry(&s, "x", notify::Urgency.NORMAL, -1, "b");
	intruder.incoming.replaces_id = secret.id;
	s.post(intruder, (Time)1000);
	assert(s.history.len() == 1 && s.history.get(0).note.summary == "secret");
}

fn void a_stack_tag_replaces_the_open_notification() @test
{
	store::Store s;
	s.init(mem, notify::DEFAULT_POLICY);
	defer s.free();
	store::Entry* first = make_entry(&s, "1");
	first.incoming.hints.stack_tag = "chat".copy((Allocator)&first.arena);
	store::Posted a      = s.post(first, (Time)1000);
	store::Entry* second = make_entry(&s, "2");
	second.incoming.hints.stack_tag = "chat".copy((Allocator)&second.arena);
	store::Posted b = s.post(second, (Time)1000);
	assert(b.id == a.id && b.replaced);
	assert(s.active.len() == 1 && s.active.get(0).note.summary == "2");
}

fn void closed_notifications_go_to_history_within_the_limit() @test
{
	notify::Policy policy = notify::DEFAULT_POLICY;
	policy.history_limit = 2;
	store::Store s;
	s.init(mem, policy);
	defer s.free();
	store::Posted a = s.post(make_entry(&s, "a"), (Time)1000);
	store::Posted b = s.post(make_entry(&s, "b"), (Time)1000);
	store::Posted c = s.post(make_entry(&s, "c"), (Time)1000);
	assert(s.close(a.id) && s.close(b.id) && s.close(c.id));
	assert(!s.close(c.id));
	assert(s.active.len() == 0);
	assert(s.history.len() == 2);
	assert(s.history.get(0).note.summary == "c");
	assert(s.history.get(1).note.summary == "b");
}

fn void transient_notifications_are_not_kept() @test
{
	store::Store s;
	s.init(mem, notify::DEFAULT_POLICY);
	defer s.free();
	store::Entry* e = make_entry(&s, "t");
	e.incoming.hints.transient = true;
	e.incoming.hints.resident = false;
	store::Posted posted = s.post(e, (Time)1000);
	assert(s.close(posted.id));
	assert(s.history.len() == 0);
}

fn void do_not_disturb_holds_back_normal_notifications() @test
{
	store::Store s;
	s.init(mem, notify::DEFAULT_POLICY);
	defer s.free();
	s.set_do_not_disturb(true);
	store::Posted quiet = s.post(make_entry(&s, "quiet"), (Time)1000);
	store::Posted loud  = s.post(make_entry(&s, "loud", notify::Urgency.CRITICAL), (Time)1000);
	assert(!quiet.shown && loud.shown);
	assert(s.active.len() == 1 && s.active.get(0).note.summary == "loud");
	assert(s.history.len() == 1 && s.history.get(0).note.summary == "quiet");
	assert(!quiet.timeout.has_value);
}

fn void the_oldest_normal_notification_makes_room() @test
{
	notify::Policy policy = notify::DEFAULT_POLICY;
	policy.max_open = 2;
	store::Store s;
	s.init(mem, policy);
	defer s.free();
	store::Posted a = s.post(make_entry(&s, "a"), (Time)1000);
	s.post(make_entry(&s, "b", notify::Urgency.CRITICAL), (Time)1000);
	store::Posted c = s.post(make_entry(&s, "c"), (Time)1000);
	assert(c.evicted && c.evicted_id == a.id);
	assert(s.active.len() == 2);
	assert(s.history.len() == 1 && s.history.get(0).note.id == a.id);
}

fn void with_only_critical_the_oldest_makes_room() @test
{
	notify::Policy policy = notify::DEFAULT_POLICY;
	policy.max_open = 2;
	store::Store s;
	s.init(mem, policy);
	defer s.free();
	store::Posted a = s.post(make_entry(&s, "a", notify::Urgency.CRITICAL), (Time)1000);
	s.post(make_entry(&s, "b", notify::Urgency.CRITICAL), (Time)1000);
	store::Posted c = s.post(make_entry(&s, "c", notify::Urgency.CRITICAL), (Time)1000);
	assert(c.evicted && c.evicted_id == a.id);
}

fn void timeouts_and_expiry_times() @test
{
	store::Store s;
	s.init(mem, notify::DEFAULT_POLICY);
	defer s.free();
	Time now             = (Time)1_000_000;
	store::Posted normal = s.post(make_entry(&s, "n"), now);
	assert(normal.timeout.value == notify::DEFAULT_NORMAL_TIMEOUT);
	assert(s.open(normal.id).note.expires.value == (Time)(1_000_000 + 10_000_000));
	store::Posted critical = s.post(make_entry(&s, "c", notify::Urgency.CRITICAL, 500), now);
	assert(!critical.timeout.has_value);
	store::Posted forever = s.post(make_entry(&s, "f", notify::Urgency.NORMAL, 0), now);
	assert(!forever.timeout.has_value);
}

fn void a_snapshot_is_a_deep_copy_without_history_pixels() @test
{
	store::Store s;
	s.init(mem, notify::DEFAULT_POLICY);
	defer s.free();
	store::Entry* e = make_entry(&s, "img");
	Allocator a     = (Allocator)&e.arena;
	e.incoming.body = "<b>hi</b> there".copy(a);
	e.incoming.hints.has_image = true;
	e.incoming.hints.image = {
		.width = 1,
		.height = 1,
		.rowstride = 3,
		.channels = 3,
		.pixels = alloc::new_array(a, char, 3)
	};
	store::Posted posted = s.post(e, (Time)1000);
	@pool()
	{
		notify::State state;
		s.fill(&state, tmem);
		assert(state.active.len == 1);
		assert(state.active[0].body.len == 2);
		assert(state.active[0].body[0].bold && state.active[0].body[0].text == "hi");
		assert(state.active[0].image.pixels.len == 3);
		assert(state.count == 1);
	};
	assert(s.close(posted.id));
	@pool()
	{
		notify::State state;
		s.fill(&state, tmem);
		assert(state.active.len == 0 && state.history.len == 1);
		assert(state.history[0].has_image && state.history[0].image.pixels.len == 0);
	};
}