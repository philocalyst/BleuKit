module bleu::notify::wire_test;
import bleu::dbus::marshal, bleu::notify, bleu::notify::wire;

const String NOTIFY_SIGNATURE = "susssasa{sv}i";

// Encode a Notify body with these actions (flat key/label list) and timeout.
fn Writer encode(String[] actions, int expire_ms)
{
	Writer w;
	w.init(tmem, NOTIFY_SIGNATURE)!!;
	w.append_string("app")!!;
	w.append_u32(7)!!;
	w.append_string("icon")!!;
	w.append_string("summary")!!;
	w.append_string("<b>x</b>")!!;
	w.begin_array("as")!!;
	foreach (word : actions) w.append_string(word)!!;
	w.end_array()!!;
	w.begin_array("a{sv}")!!;
	w.end_array()!!;
	w.append_i32(expire_ms)!!;
	w.finish()!!;
	return w;
}

fn wire::Incoming decode(Writer* w)
{
	Reader r;
	r.init(w.bytes(), NOTIFY_SIGNATURE)!!;
	wire::Incoming incoming;
	wire::read_notify(&r, tmem, &incoming)!!;
	return incoming;
}

fn void the_arguments_are_read_in_order() @test
{
	@pool()
	{
		Writer w          = encode({ "default", "Open", "dangling" }, -5);
		wire::Incoming in = decode(&w);
		assert(in.app_name == "app" && in.replaces_id == 7);
		assert(in.app_icon == "icon" && in.summary == "summary");
		assert(in.body == "<b>x</b>");
		// An odd last string has no label and is dropped.
		assert(in.actions.len == 1);
		assert(in.actions[0].key == "default" && in.actions[0].label == "Open");
		assert(in.expire_ms == -1);
	};
}

fn void duplicate_and_empty_action_keys_are_dropped() @test
{
	@pool()
	{
		Writer w          = encode({ "a", "A", "a", "B", "", "C", "c", "C" }, 0);
		wire::Incoming in = decode(&w);
		assert(in.actions.len == 2);
		assert(in.actions[0].key == "a" && in.actions[0].label == "A");
		assert(in.actions[1].key == "c");
		assert(in.expire_ms == 0);
	};
}

fn void actions_stop_at_the_limit() @test
{
	@pool()
	{
		// Forty pairs with distinct keys: only the first MAX_ACTIONS may survive.
		DString key;
		key.init(tmem);
		String[] list = alloc::new_array(tmem, String, 40);
		for (usz k = 0; k < 40; k += 2)
		{
			key.clear();
			key.append_char('a');
			key.append_char((char)('a' + k / 2));
			list[k] = key.str_view().copy(tmem);
			list[k + 1] = "label";
		}
		Writer w          = encode(list, 0);
		wire::Incoming in = decode(&w);
		assert(in.actions.len == (sz)notify::MAX_ACTIONS);
	};
}

fn void expiry_is_kept_between_minus_one_and_a_day() @test
{
	@pool()
	{
		Writer w = encode({ }, -7);
		assert(decode(&w).expire_ms == -1);
		Writer big = encode({ }, 2_000_000_000);
		assert(decode(&big).expire_ms == notify::MAX_EXPIRE_MS);
	};
}