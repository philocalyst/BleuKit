<*
 Sending through the freedesktop notification interface, on the session bus. The
 call is the same `Notify` the server answers, so this works with our centre and
 with any other daemon that owns the name.

 The bus connection is made when the sender is opened, on the opening thread.
*>
module bleu::notify::sender_fdo @feat(LINUX);
import std::time, bleu::error, bleu::availability, bleu::dbus::connection, bleu::dbus::marshal, bleu::dbus::message, bleu::dbus::proxy, bleu::notify, bleu::notify::sender;

const String DEST = "org.freedesktop.Notifications";
const String PATH = "/org/freedesktop/Notifications";
const String IFACE = "org.freedesktop.Notifications";
const String NOTIFY_SIGNATURE = "susssasa{sv}i";

// How long a Notify call waits for the server to answer.
const Duration CALL_TIMEOUT = (Duration)25_000_000; // 25 s, microseconds

struct FdoSender
{
	Connection conn;
}

const sender::SenderDriver DRIVER = {
	.info = { "fdo", "org.freedesktop.Notifications.Notify on the session bus", 10 },
	.open_fn = &open_fdo,
	.close_fn = &close_fdo,
	.send_fn = &send_fdo,
};

fn void*? open_fdo(Allocator allocator, sender::Features* features)
{
	features.init(availability::YES);
	FdoSender* self = alloc::new(allocator, FdoSender);
	self.conn.init(allocator);
	if (catch err = self.conn.open_session())
	{
		self.conn.free();
		alloc::free(allocator, self);
		return err~;
	}
	return self;
}

fn void close_fdo(Allocator allocator, void* state)
{
	FdoSender* self = (FdoSender*)state;
	self.conn.free();
	alloc::free(allocator, self);
}

// Notify(app, replaces, icon, summary, body, actions, hints, timeout) -> id.
fn notify::NoteId? send_fdo(void* state, sender::Request* request)
{
	FdoSender* self = (FdoSender*)state;
	Proxy server = proxy::for_object(&self.conn, DEST, PATH, IFACE)!;
	Message* call = server.new_call(mem, "Notify")!;
	defer call.release();
	Writer* w = call.body_writer(NOTIFY_SIGNATURE)!;
	w.append_string(request.app_name)!;
	w.append_u32(request.replaces_id)!;
	w.append_string(request.app_icon)!;
	w.append_string(request.summary)!;
	w.append_string(request.body)!;
	w.begin_array("as")!;
	foreach (action : request.actions)
	{
		w.append_string(action.key)!;
		w.append_string(action.label)!;
	}
	w.end_array()!;
	write_hints(w, request)!;
	w.append_i32(request.expire_ms)!;
	Message* reply = self.conn.call(call, CALL_TIMEOUT)!;
	defer reply.release();
	return reply.reader()!.read_u32()!;
}

// The `a{sv}` hints: urgency always, the others when they are set.
fn void? write_hints(Writer* w, sender::Request* request)
{
	w.begin_array("a{sv}")!;
	put_byte(w, "urgency", (char)request.urgency)!;
	if (request.category.len > 0) put_string(w, "category", request.category)!;
	if (request.desktop_entry.len > 0) put_string(w, "desktop-entry", request.desktop_entry)!;
	if (request.image_path.len > 0) put_string(w, "image-path", request.image_path)!;
	if (request.sound_name.len > 0) put_string(w, "sound-name", request.sound_name)!;
	if (request.suppress_sound) put_bool(w, "suppress-sound", true)!;
	if (request.resident) put_bool(w, "resident", true)!;
	if (request.transient) put_bool(w, "transient", true)!;
	w.end_array()!;
}

fn void? put_byte(Writer* w, String key, char value)
{
	w.begin_dict_entry()!;
	w.append_string(key)!;
	w.begin_variant("y")!;
	w.append_byte(value)!;
	w.end_variant()!;
	w.end_dict_entry()!;
}

fn void? put_bool(Writer* w, String key, bool value)
{
	w.begin_dict_entry()!;
	w.append_string(key)!;
	w.begin_variant("b")!;
	w.append_bool(value)!;
	w.end_variant()!;
	w.end_dict_entry()!;
}

fn void? put_string(Writer* w, String key, String value)
{
	w.begin_dict_entry()!;
	w.append_string(key)!;
	w.begin_variant("s")!;
	w.append_string(value)!;
	w.end_variant()!;
	w.end_dict_entry()!;
}
