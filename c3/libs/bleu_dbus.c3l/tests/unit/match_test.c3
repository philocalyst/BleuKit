// Unit tests for bleu::dbus::match: rendering of rules for AddMatch (including
// the quoting rule for apostrophes) and their evaluation against messages.
module bleu::dbus::match_test;
import bleu::dbus::match, bleu::dbus::message, bleu::dbus::testing, bleu::error;

fn void renders_rules_in_bus_syntax() @test
{
	match::Match rule;
	rule.init(mem);
	defer rule.free();
	rule.with_type(MessageType.SIGNAL)!!;
	rule.with_interface("org.freedesktop.DBus")!!;
	rule.with_member("NameOwnerChanged")!!;
	rule.with_arg(0, "org.bleu.Mock")!!;
	assert(rule.rule_text()
		== "type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.bleu.Mock'");
}

fn void quotes_apostrophes_inside_values() @test
{
	match::Match rule;
	rule.init(mem);
	defer rule.free();
	rule.with_arg(1, "it's")!!;
	assert(rule.rule_text() == "arg1='it'\\''s'");
}

fn void rejects_names_the_bus_would_refuse() @test
{
	match::Match rule;
	rule.init(mem);
	defer rule.free();
	testing::@expect_fault(rule.with_member("a.b"), error::INVALID_ARGUMENT);
	testing::@expect_fault(rule.with_sender("nodot"), error::INVALID_ARGUMENT);
	testing::@expect_fault(rule.with_arg(8, "x"), error::INVALID_ARGUMENT);
	assert(rule.rule_text().len == 0);
}

fn void accepts_only_matching_messages() @test
{
	@pool()
	{
		Message* m = message::signal(mem, "/org/bleu/Mock", "org.bleu.Mock", "Ping")!!;
		defer m.release();
		m.sender = ":1.7";
		match::Match exact;
		exact.init(mem);
		defer exact.free();
		exact.with_sender(":1.7")!!;
		exact.with_member("Ping")!!;
		exact.with_path("/org/bleu/Mock")!!;
		assert(exact.accepts(m, ":1.7"));
		assert(!exact.accepts(m, ":1.8"));

		match::Match other;
		other.init(mem);
		defer other.free();
		other.with_member("Pong")!!;
		assert(!other.accepts(m, ""));

		match::Match tree;
		tree.init(mem);
		defer tree.free();
		tree.with_path_namespace("/org/bleu")!!;
		assert(tree.accepts(m, ""));
		match::Match sibling;
		sibling.init(mem);
		defer sibling.free();
		sibling.with_path_namespace("/org/bleu/Mo")!!;
		assert(!sibling.accepts(m, ""));
	};
}