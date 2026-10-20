<*
 Match rules: which broadcast signals and other messages the bus should send
 to a connection, and the same test applied to a message on arrival.

 A rule is built with the `with_*` methods and is rendered into the string the
 bus understands (`type='signal',member='X'`). The rule keeps its own copies of
 its values, so the caller's strings need not outlive it. Values are quoted
 with single quotes, and an apostrophe inside a value is written `'\''`.

 Sources: D-Bus specification, "Match Rules" (keys, the quoting rules, and
 `path_namespace` and `argN` semantics), "Method: org.freedesktop.DBus.AddMatch".
*>
module bleu::dbus::match;
import bleu::error, bleu::dbus::message, bleu::dbus::marshal, bleu::dbus::signature;

<* Number of argument positions a rule can constrain (arg0 .. arg7). *>
const MAX_ARGUMENTS = 8;

<* Message type names as the bus spells them in a rule. *>
const SIGNAL_TYPE = "signal";
const METHOD_CALL_TYPE = "method_call";
const METHOD_RETURN_TYPE = "method_return";
const ERROR_TYPE = "error";

<*
 A match rule. Create it with `Match.init`, give it constraints with the
 `with_*` methods, and release it with `free`.
*>
struct Match
{
	Allocator allocator;
	DString text;
	MessageType type;
	bool has_type;
	String sender;
	String interface_name;
	String member;
	String path;
	String path_namespace;
	String destination;
	String[MAX_ARGUMENTS] args;
	bool[MAX_ARGUMENTS] has_arg;
}

<* Start an empty rule (matching every message) that will be stored in `allocator`. *>
fn void Match.init(&self, Allocator allocator)
{
	*self = { .allocator = allocator };
	self.text.init(allocator);
}

<* Release the rule's text and copies. *>
fn void Match.free(&self) => self.text.free();

<* The rule in bus syntax, for AddMatch and RemoveMatch. *>
fn String Match.rule_text(&self) @inline => self.text.str_view();

<*
 Only messages of this type.

 @return? error::INVALID_ARGUMENT : "The type cannot be matched (only signal, method call, method return and error)"
*>
fn void? Match.with_type(&self, MessageType type)
{
	String name;
	switch (type)
	{
		case SIGNAL: name = SIGNAL_TYPE;
		case METHOD_CALL: name = METHOD_CALL_TYPE;
		case METHOD_RETURN: name = METHOD_RETURN_TYPE;
		case ERROR: name = ERROR_TYPE;
		default: return error::INVALID_ARGUMENT~;
	}
	self.has_type = true;
	self.type = type;
	append_key(self, "type", name);
}

<*
 Only messages from this sender: a unique name (`:1.42`) or a well-known name.

 @return? error::INVALID_ARGUMENT : "The name is not a bus name"
*>
fn void? Match.with_sender(&self, String name)
{
	if (!names::is_bus_name(name)) return error::INVALID_ARGUMENT~;
	self.sender = copy_value(self, name);
	append_key(self, "sender", name);
}

<* Only messages on this interface. @return? error::INVALID_ARGUMENT : "Not an interface name" *>
fn void? Match.with_interface(&self, String name)
{
	if (!names::is_interface(name)) return error::INVALID_ARGUMENT~;
	self.interface_name = copy_value(self, name);
	append_key(self, "interface", name);
}

<* Only messages with this member name. @return? error::INVALID_ARGUMENT : "Not a member name" *>
fn void? Match.with_member(&self, String name)
{
	if (!names::is_member(name)) return error::INVALID_ARGUMENT~;
	self.member = copy_value(self, name);
	append_key(self, "member", name);
}

<* Only messages from exactly this object path. @return? error::INVALID_ARGUMENT : "Not an object path" *>
fn void? Match.with_path(&self, String path)
{
	if (!names::is_object_path(path)) return error::INVALID_ARGUMENT~;
	self.path = copy_value(self, path);
	append_key(self, "path", path);
}

<*
 Only messages from this object path and the paths beneath it (`/a` matches
 `/a` and `/a/b`, but not `/ab`).

 @return? error::INVALID_ARGUMENT : "Not an object path"
*>
fn void? Match.with_path_namespace(&self, String path)
{
	if (!names::is_object_path(path)) return error::INVALID_ARGUMENT~;
	self.path_namespace = copy_value(self, path);
	append_key(self, "path_namespace", path);
}

<*
 Only messages whose argument `index` is this string (arg0 .. arg7).

 @return? error::INVALID_ARGUMENT : "The index is past the supported arguments"
*>
fn void? Match.with_arg(&self, usz index, String value)
{
	if (index >= MAX_ARGUMENTS) return error::INVALID_ARGUMENT~;
	self.args[index] = copy_value(self, value);
	self.has_arg[index] = true;
	DString key;
	key.init(tmem);
	key.appendf("arg%d", (long)index)!!;
	append_key(self, key.str_view(), value);
}

<*
 Whether `message` satisfies every constraint of this rule, given that the
 rule's sender resolves to `sender_owner` (the unique name that a well-known
 sender currently owns; empty when the rule names no sender).

 @param sender_owner : "The unique name the rule's sender refers to, or empty"
*>
fn bool Match.accepts(&self, Message* message, String sender_owner)
{
	if (self.has_type && message.type != self.type) return false;
	if (self.sender.len > 0 && (sender_owner.len == 0 || message.sender != sender_owner)) return false;
	if (self.interface_name.len > 0 && message.interface_name != self.interface_name) return false;
	if (self.member.len > 0 && message.member != self.member) return false;
	if (self.path.len > 0 && message.path != self.path) return false;
	if (self.path_namespace.len > 0 && !in_namespace(message.path, self.path_namespace)) return false;
	if (self.destination.len > 0 && message.destination != self.destination) return false;
	for (usz i = 0; i < MAX_ARGUMENTS; i++)
	{
		if (self.has_arg[i] && !argument_is(message, i, self.args[i])) return false;
	}
	return true;
}

// The path itself, or a path beneath it ("/a" contains "/a/b" but not "/ab").
fn bool in_namespace(String path, String ns) @private
{
	if (ns == "/") return true;
	if (path == ns) return true;
	return path.len > ns.len && path[0:ns.len] == ns && path[ns.len] == '/';
}

// True when argument `index` is a string or object path equal to `value`.
fn bool argument_is(Message* message, usz index, String value) @private
{
	TypeIterator types = signature::iterate(message.signature);
	for (usz position = 0; types.has_next(); position++)
	{
		if (try type = types.next())
		{
			if (position == index) return text_argument_is(message, index, type, value);
			continue;
		}
		return false;
	}
	return false;
}

// Whether the string-like argument `index` of type `type` equals `value`.
fn bool text_argument_is(Message* message, usz index, String type, String value) @private
{
	if (type != "s" && type != "o") return false;
	if (try r = message.reader())
	{
		for (usz i = 0; i < index; i++)
		{
			if (catch r.skip_value()) return false;
		}
		if (type == "o")
		{
			if (try text = r.read_object_path()) return text == value;
			return false;
		}
		if (try text = r.read_string()) return text == value;
	}
	return false;
}

// Appends `key='value'`, with a comma before it unless it is the first key.
fn void append_key(Match* self, String key, String value) @private
{
	if (self.text.len() > 0) self.text.append_char(',');
	self.text.append_string(key);
	self.text.append_char('=');
	self.text.append_char('\'');
	foreach (c : value)
	{
		if (c == '\'') self.text.append_string("'\\''");
		else self.text.append_char(c);
	}
	self.text.append_char('\'');
}

// A private copy of `value` in the rule's allocator.
fn String copy_value(Match* self, String value) @private => value.copy(self.allocator);
