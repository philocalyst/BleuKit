module bleu::hotkey::portal_path_test;
import std::io, bleu::dbus::names, bleu::hotkey::portal_path, bleu::error;

// The SENDER element is the unique name without ':' and with '.' replaced by '_'.
fn void sender_element_follows_the_spec() @test
{
	String element = portal_path::sender_element(":1.42", mem)!!;
	defer element.free(mem);
	assert(element == "1_42");
	String long_name = portal_path::sender_element(":1.1234.7", mem)!!;
	defer long_name.free(mem);
	assert(long_name == "1_1234_7");
}

// The worked example of the Request spec: a sender of :1.42 and a token of t gives this path.
fn void request_path_matches_the_worked_example() @test
{
	String path = portal_path::request_path(":1.42", "t", mem)!!;
	defer path.free(mem);
	assert(path == "/org/freedesktop/portal/desktop/request/1_42/t");
	assert(names::is_object_path(path), "the result is a valid D-Bus object path");
}

fn void session_path_uses_the_session_branch() @test
{
	String path = portal_path::session_path(":1.42", "bleu_hotkey_9", mem)!!;
	defer path.free(mem);
	assert(path == "/org/freedesktop/portal/desktop/session/1_42/bleu_hotkey_9");
	assert(names::is_object_path(path));
}

// Only a unique name can be mapped: well-known names and empty strings are refused.
fn void well_known_names_are_refused() @test
{
	assert(@catch(portal_path::request_path("org.example.App", "t", mem)) == error::INVALID_ARGUMENT);
	assert(@catch(portal_path::request_path("", "t", mem)) == error::INVALID_ARGUMENT);
	assert(@catch(portal_path::request_path(":", "t", mem)) == error::INVALID_ARGUMENT);
}

// A token must be a single object path element; anything else would make an invalid path.
fn void tokens_must_be_path_elements() @test
{
	assert(@catch(portal_path::request_path(":1.42", "a/b", mem)) == error::INVALID_ARGUMENT);
	assert(@catch(portal_path::request_path(":1.42", "a-b", mem)) == error::INVALID_ARGUMENT);
	assert(@catch(portal_path::request_path(":1.42", "", mem)) == error::INVALID_ARGUMENT);
	assert(portal_path::is_token("bleu_hotkey_0"));
}

// Tokens made from a counter are path elements, and differ from one another.
fn void counter_tokens_are_distinct() @test
{
	String first = portal_path::token(0, mem);
	defer first.free(mem);
	String second = portal_path::token(1, mem);
	defer second.free(mem);
	assert(first == "bleu_hotkey_0" && second == "bleu_hotkey_1");
	assert(portal_path::is_token(first));
}