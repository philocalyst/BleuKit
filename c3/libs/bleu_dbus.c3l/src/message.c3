<*
 D-Bus messages: the header fields, the four message types, parsing from bytes
 and building for transmission.

 A `Message` is a heap object that owns its memory: the text of its header
 fields and its received bytes live in its own arena, its outgoing body in a
 writer. `release` frees all of it, together with any descriptors the message
 received and still owns. Messages are always used through pointers.

 Layout (spec "Message Format"): a 16-byte fixed header (endianness, type, flags,
 protocol version, body length, serial, header field array length), the header
 field array padded to an 8-byte boundary, then the body. Maximum total length
 is 2^27 bytes (128 MiB); the maximum array length is 2^26 bytes.

 Sources: D-Bus specification, "Message Format", "Header Fields", "Message Types";
 systemd sd-bus src/libsystemd/sd-bus/bus-message.c (BusMessageHeader is the same
 16-byte packed struct; body starts at ALIGN8(fields_size); message_size check
 at parse time; serial 0 rejected).
*>
module bleu::dbus::message;
import bleu::error, bleu::dbus::signature, bleu::dbus::names, bleu::dbus::marshal, bleu::dbus::value;
import bleu::dbus::transport;
import std::collections::list;

<* Largest message: header, header padding and body together, 2^27 bytes. *>
const MAX_MESSAGE_LENGTH = 134217728;

<* Bytes of the fixed header, before the header field array. *>
const FIXED_HEADER_LENGTH = 16;

<* Signature of the header: four bytes, serial, length, the field array. *>
const HEADER_SIGNATURE = "yyyyuua(yv)";

<* Protocol major version this implementation speaks. *>
const PROTOCOL_VERSION = 1;

<* Endianness flag for little-endian messages (the first header byte). *>
const char LITTLE_ENDIAN_FLAG = 'l';

<* Endianness flag for big-endian messages. *>
const char BIG_ENDIAN_FLAG = 'B';

<* Message type, in header byte 1. Ordinals match the wire codes. *>
enum MessageType : char
{
	INVALID,
	METHOD_CALL,
	METHOD_RETURN,
	ERROR,
	SIGNAL,
	UNKNOWN, // a type code this implementation does not know: ignored
}

<* Header flag: the sender does not want a reply (flags bit 0x1). *>
const char FLAG_NO_REPLY_EXPECTED = 0x1;

<* Header flag: the bus must not start a service to deliver this (flags bit 0x2). *>
const char FLAG_NO_AUTO_START = 0x2;

<* Header flag: the caller accepts interactive authorization (flags bit 0x4). *>
const char FLAG_ALLOW_INTERACTIVE_AUTHORIZATION = 0x4;

// Header field codes (spec "Header Fields").
const char FIELD_PATH         = 1;
const char FIELD_INTERFACE    = 2;
const char FIELD_MEMBER       = 3;
const char FIELD_ERROR_NAME   = 4;
const char FIELD_REPLY_SERIAL = 5;
const char FIELD_DESTINATION  = 6;
const char FIELD_SENDER       = 7;
const char FIELD_SIGNATURE    = 8;
const char FIELD_UNIX_FDS     = 9;

<* Object path the specification reserves for the local implementation. *>
const LOCAL_PATH = "/org/freedesktop/DBus/Local";

<* Interface the specification reserves for the local implementation. *>
const LOCAL_INTERFACE = "org.freedesktop.DBus.Local";

<*
 A message, parsed or under construction.

 Header fields that a message does not carry are empty strings (for the text
 fields) or zero (for the serials and the descriptor count). `path` and
 `interface` are the names the specification defines for each field.
*>
struct Message
{
	Allocator parent;
	DynamicArenaAllocator storage;
	MessageType type;
	char flags;
	bool big_endian;
	uint serial;
	uint reply_serial;
	uint unix_fds;
	String path;
	String interface_name;
	String member;
	String error_name;
	String destination;
	String sender;
	String signature;
	String body;
	Writer writer;
	bool has_writer;
	List{int} fds;
	bool owns_fds;
}

// A message with its storage ready and no fields set.
fn Message* create(Allocator parent, MessageType type) @private
{
	Message* m = alloc::new(parent, Message);
	m.parent = parent;
	m.storage.init(parent, 512);
	m.type = type;
	m.fds.init(parent);
	return m;
}

<*
 Free the message: its arena, its body writer, and the descriptors it owns.
 The message must not be used afterwards.
*>
fn void Message.release(&self)
{
	if (self.owns_fds)
	{
		foreach (fd : self.fds) transport::close_fd(fd);
	}
	if (self.has_writer) self.writer.free();
	self.fds.free();
	Allocator parent = self.parent;
	self.storage.free();
	alloc::free(parent, self);
}

<*
 A METHOD_CALL to `member` of `interface` on `path` at `destination`. An empty
 `destination` means the message is not routed by a bus. An empty `interface`
 is allowed for calls but is discouraged.

 @param parent : "Allocator for the message; the message keeps its own arena in it"
 @return? error::INVALID_ARGUMENT : "A name is not valid"
*>
fn Message*? method_call(Allocator parent, String destination, String path, String iface, String member)
{
	if (!names::is_object_path(path) || !names::is_member(member)) return error::INVALID_ARGUMENT~;
	if (iface.len > 0 && !names::is_interface(iface)) return error::INVALID_ARGUMENT~;
	if (destination.len > 0 && !names::is_bus_name(destination)) return error::INVALID_ARGUMENT~;
	Message* m = create(parent, METHOD_CALL);
	m.path = path.copy(&m.storage);
	m.member = member.copy(&m.storage);
	m.interface_name = iface.copy(&m.storage);
	m.destination = destination.copy(&m.storage);
	return m;
}

<*
 A SIGNAL emitted from `path`. Signals carry no reply.

 @return? error::INVALID_ARGUMENT : "A name is not valid"
*>
fn Message*? signal(Allocator parent, String path, String iface, String member, String destination = "")
{
	if (!names::is_object_path(
		path
	) || !names::is_interface(iface) || !names::is_member(member)) return error::INVALID_ARGUMENT~;
	if (destination.len > 0 && !names::is_bus_name(destination)) return error::INVALID_ARGUMENT~;
	Message* m = create(parent, SIGNAL);
	m.path = path.copy(&m.storage);
	m.interface_name = iface.copy(&m.storage);
	m.member = member.copy(&m.storage);
	m.destination = destination.copy(&m.storage);
	return m;
}

<*
 A METHOD_RETURN answering `call`. Its body is written with `body_writer`.
*>
fn Message*? reply(Allocator parent, Message* call)
{
	Message* m = create(parent, METHOD_RETURN);
	m.reply_serial = call.serial;
	m.destination = call.sender.copy(&m.storage);
	return m;
}

<*
 An ERROR answering `call`, with `error_name` and a human-readable `text`.

 @return? error::INVALID_ARGUMENT : "The error name is not valid"
*>
fn Message*? error_reply(Allocator parent, Message* call, String error_name, String text)
{
	if (!names::is_error_name(error_name)) return error::INVALID_ARGUMENT~;
	Message* m = create(parent, ERROR);
	m.reply_serial = call.serial;
	m.error_name = error_name.copy(&m.storage);
	m.destination = call.sender.copy(&m.storage);
	Writer* w = m.body_writer("s")!;
	w.append_string(text)!;
	return m;
}

<*
 The writer for the body of an outgoing message, initialised for `signature`.
 Write the arguments with it, then the message is sent. Calling it again
 discards what was written before.

 @return? error::INVALID_ARGUMENT : "The signature is not valid"
*>
fn Writer*? Message.body_writer(&self, String signature)
{
	if (self.has_writer) self.writer.free();
	self.has_writer = false;
	self.writer.init(self.parent, signature.copy(&self.storage), false)!;
	self.has_writer = true;
	return &self.writer;
}

<*
 Add a descriptor to an outgoing message and return its index for a
 UNIX_FD argument. The message does not take ownership: the caller keeps the
 descriptor open until the message has been sent.
*>
fn uint Message.attach_fd(&self, int fd)
{
	self.fds.push(fd);
	return (uint)self.fds.len() - 1;
}

<*
 The descriptor a UNIX_FD argument refers to.

 @return? error::PROTOCOL : "The index is past the descriptors the message carries"
*>
fn int? Message.unix_fd(&self, uint index)
{
	if (index >= (uint)self.fds.len()) return error::PROTOCOL~;
	return self.fds.get((sz)index);
}

<*
 The body bytes: those of a received message, or those written so far.
*>
fn String Message.body_bytes(&self) => self.has_writer ? self.writer.bytes() : self.body;

<*
 A reader over the body, positioned at its first argument.

 @return? error::INVALID_ARGUMENT : "The message signature is not valid"
*>
fn Reader? Message.reader(&self)
{
	Reader r;
	r.init(self.body_bytes(), self.has_writer ? self.writer.signature : self.signature, self.big_endian)!;
	return r;
}

<* True for an ERROR message. *>
fn bool Message.is_error(&self) @inline => self.type == ERROR;

<*
 The total length of the message whose fixed header starts `prefix`, from its
 body and field array lengths. Framing reads the first 16 bytes of a message
 and then this many bytes in all.

 @param prefix : "At least the first 16 bytes of a message"
 @return? error::INVALID_ARGUMENT : "Fewer than 16 bytes"
 @return? error::PROTOCOL : "Bad endianness flag or version, a field array over 2^26 bytes, or a message over 128 MiB"
*>
fn usz? frame_length(String prefix)
{
	if (prefix.len < FIXED_HEADER_LENGTH) return error::INVALID_ARGUMENT~;
	bool big = endianness_of(prefix)!;
	if (prefix[3] != PROTOCOL_VERSION) return error::PROTOCOL~;
	usz body   = fixed_uint(prefix, 4, big);
	usz fields = fixed_uint(prefix, 12, big);
	if (fields > marshal::MAX_ARRAY_LENGTH) return error::PROTOCOL~;
	usz total = align8(FIXED_HEADER_LENGTH + fields) + body;
	if (total > MAX_MESSAGE_LENGTH) return error::PROTOCOL~;
	return total;
}

<*
 Parse one complete message from `frame`, which must be exactly one message
 (as framed by `frame_length`). The bytes are copied into the message, so
 `frame` may be reused.

 The message's descriptors are taken from the front of `descriptors`, which
 holds the descriptors received so far in arrival order: the first
 `unix_fds` of them belong to this message. They are removed from the list and
 owned by the message from then on (closed by `release`). On failure the list
 is left unchanged.

 @param parent : "Allocator for the message"
 @param frame : "The message bytes"
 @param descriptors : "Received descriptors in arrival order, or null when none can arrive"
 @return? error::PROTOCOL : "The bytes do not form a valid message, or fewer descriptors arrived than it declares"
*>
fn Message*? parse(Allocator parent, String frame, List{int}* descriptors = null)
{
	usz total = frame_length(frame)!;
	if (frame.len != total) return error::PROTOCOL~;
	Message* m = create(parent, INVALID);
	if (catch err = fill(m, frame, descriptors))
	{
		m.release();
		return err~;
	}
	m.owns_fds = true;
	return m;
}

<*
 The text of an ERROR message: its first argument, when that is a string.

 @return? error::INVALID_STATE : "The message does not carry a string argument"
*>
fn String? Message.error_text(&self)
{
	if (self.type != ERROR || self.signature.len == 0
		|| self.signature[0] != signature::STRING) return error::INVALID_STATE~;
	Reader r = self.reader()!;
	return r.read_string();
}

// Fills this message from `frame` (already length-checked) and validates it.
fn void? fill(Message* self, String frame, List{int}* descriptors) @private
{
	self.big_endian = endianness_of(frame)!;
	String stored = frame.copy(&self.storage);
	Reader r;
	r.init(stored, HEADER_SIGNATURE, self.big_endian)!;
	r.read_byte()!;
	self.type = message_type(r.read_byte()!);
	self.flags = r.read_byte()!;
	r.read_byte()!;
	usz body_length = (usz)r.read_u32()!;
	self.serial = r.read_u32()!;
	if (self.serial == 0) return error::PROTOCOL~;
	read_fields(self, &r)!;
	usz body_at = align8(r.position());
	for (usz i = r.position(); i < body_at; i++)
	{
		if (stored[i] != 0) return error::PROTOCOL~;
	}
	if (body_at + body_length != stored.len) return error::PROTOCOL~;
	self.body = stored[body_at:body_length];
	usz available = descriptors == null ? 0 : (usz)descriptors.len();
	if (self.unix_fds > available) return error::PROTOCOL~;
	validate(self)!;
	for (usz i = 0; i < self.unix_fds; i++)
	{
		self.fds.push(descriptors.get(0));
		descriptors.remove_at(0);
	}
}

// Reads the header field array into `m`, rejecting duplicates and wrong types.
fn void? read_fields(Message* m, Reader* r) @private
{
	r.begin_array()!;
	ulong seen = 0;
	while (r.has_more())
	{
		r.begin_struct()!;
		char code = r.read_byte()!;
		if (code == 0) return error::PROTOCOL~;
		String type = r.begin_variant()!;
		if (code < 64)
		{
			if ((seen & ((ulong)1 << code)) != 0) return error::PROTOCOL~;
			seen |= (ulong)1 << code;
		}
		read_field(m, r, code, type)!;
		r.end_variant()!;
		r.end_struct()!;
	}
	r.end_array()!;
}

// One field's value, of the type the specification gives it.
fn void? read_field(Message* m, Reader* r, char code, String type) @private
{
	switch (code)
	{
		case FIELD_PATH:
			expect_type(type, "o")!;
			m.path = r.read_object_path()!;
		case FIELD_INTERFACE:
			expect_type(type, "s")!;
			m.interface_name = r.read_string()!;
		case FIELD_MEMBER:
			expect_type(type, "s")!;
			m.member = r.read_string()!;
		case FIELD_ERROR_NAME:
			expect_type(type, "s")!;
			m.error_name = r.read_string()!;
		case FIELD_REPLY_SERIAL:
			expect_type(type, "u")!;
			m.reply_serial = r.read_u32()!;
		case FIELD_DESTINATION:
			expect_type(type, "s")!;
			m.destination = r.read_string()!;
		case FIELD_SENDER:
			expect_type(type, "s")!;
			m.sender = r.read_string()!;
		case FIELD_SIGNATURE:
			expect_type(type, "g")!;
			m.signature = r.read_signature()!;
		case FIELD_UNIX_FDS:
			expect_type(type, "u")!;
			m.unix_fds = r.read_u32()!;
		default:
			// Unknown fields are ignored, as the specification requires.
			r.skip_value()!;
	}
}

// PROTOCOL unless a known header field carries the type the specification gives it.
fn void? expect_type(String got, String want) @private
{
	if (got != want) return error::PROTOCOL~;
}

// Checks the rules the specification gives for each message type.
fn void? validate(Message* m) @private
{
	switch (m.type)
	{
		case METHOD_CALL:
			if (m.path.len == 0 || m.member.len == 0) return error::PROTOCOL~;
			if (m.path == LOCAL_PATH || m.interface_name == LOCAL_INTERFACE) return error::PROTOCOL~;
		case SIGNAL:
			if (m.path.len == 0 || m.interface_name.len == 0 || m.member.len == 0) return error::PROTOCOL~;
			if (m.path == LOCAL_PATH || m.interface_name == LOCAL_INTERFACE) return error::PROTOCOL~;
		case METHOD_RETURN:
			if (m.reply_serial == 0) return error::PROTOCOL~;
		case ERROR:
			if (m.reply_serial == 0 || m.error_name.len == 0) return error::PROTOCOL~;
		case INVALID:
		case UNKNOWN:
			return;
	}
}

// The endianness flag of a message: true for big-endian.
// @return? error::PROTOCOL : "The flag is neither 'l' nor 'B'"
fn bool? endianness_of(String frame) @private
{
	switch (frame[0])
	{
		case LITTLE_ENDIAN_FLAG: return false;
		case BIG_ENDIAN_FLAG: return true;
		default: return error::PROTOCOL~;
	}
}

// The message type of a header byte; codes this version does not define are UNKNOWN.
fn MessageType message_type(char code)
{
	switch (code)
	{
		case 1: return METHOD_CALL;
		case 2: return METHOD_RETURN;
		case 3: return ERROR;
		case 4: return SIGNAL;
		default: return UNKNOWN;
	}
}

// A 32-bit unsigned value at `at`, in the message's byte order.
fn usz fixed_uint(String data, usz at, bool big) @private
{
	usz v = 0;
	for (usz i = 0; i < 4; i++)
	{
		usz shift = big ? (3 - i) * 8 : i * 8;
		v |= (usz)(char)data[at + i] << shift;
	}
	return v;
}

// Rounds up to a multiple of 8, the boundary the message body starts on.
fn usz align8(usz n) @inline => (n + 7) & ~(usz)7;

<*
 Send-side encoding: append the wire form of this message to `out`. The body
 writer, if any, must be complete.

 @return? error::INVALID_STATE : "The body is not complete for its signature"
 @return? error::INVALID_ARGUMENT : "The message exceeds 128 MiB, or it has no serial"
*>
fn void? Message.encode(&self, DString* out)
{
	if (self.serial == 0) return error::INVALID_ARGUMENT~;
	String sig = "";
	if (self.has_writer)
	{
		self.writer.finish()!;
		sig = self.writer.signature;
	}
	String body = self.body_bytes();
	Writer hw;
	hw.init(mem, HEADER_SIGNATURE)!;
	defer hw.free();
	hw.append_byte(LITTLE_ENDIAN_FLAG)!;
	hw.append_byte((char)self.type)!;
	hw.append_byte(self.flags)!;
	hw.append_byte(PROTOCOL_VERSION)!;
	hw.append_u32((uint)body.len)!;
	hw.append_u32(self.serial)!;
	hw.begin_array("a(yv)")!;
	if (self.path.len > 0) append_text_field(&hw, FIELD_PATH, "o", self.path)!;
	if (self.interface_name.len > 0) append_text_field(&hw, FIELD_INTERFACE, "s", self.interface_name)!;
	if (self.member.len > 0) append_text_field(&hw, FIELD_MEMBER, "s", self.member)!;
	if (self.error_name.len > 0) append_text_field(&hw, FIELD_ERROR_NAME, "s", self.error_name)!;
	if (self.reply_serial != 0) append_u32_field(&hw, FIELD_REPLY_SERIAL, self.reply_serial)!;
	if (self.destination.len > 0) append_text_field(&hw, FIELD_DESTINATION, "s", self.destination)!;
	if (sig.len > 0) append_text_field(&hw, FIELD_SIGNATURE, "g", sig)!;
	if (self.fds.len() > 0) append_u32_field(&hw, FIELD_UNIX_FDS, (uint)self.fds.len())!;
	hw.end_array()!;
	hw.align(signature::ALIGN_8);
	if (hw.size() + body.len > MAX_MESSAGE_LENGTH) return error::INVALID_ARGUMENT~;
	out.append_bytes(hw.bytes());
	out.append_string(body);
}

// One header field: a STRUCT of its code and a VARIANT holding a string-like value.
fn void? append_text_field(Writer* hw, char code, String type, String text) @private
{
	hw.begin_struct()!;
	hw.append_byte(code)!;
	hw.begin_variant(type)!;
	switch (type[0])
	{
		case signature::OBJECT_PATH: hw.append_object_path(text)!;
		case signature::SIGNATURE: hw.append_signature(text)!;
		default: hw.append_string(text)!;
	}
	hw.end_variant()!;
	hw.end_struct()!;
}

// One header field: a STRUCT of its code and a VARIANT holding a UINT32.
fn void? append_u32_field(Writer* hw, char code, uint value) @private
{
	hw.begin_struct()!;
	hw.append_byte(code)!;
	hw.begin_variant("u")!;
	hw.append_u32(value)!;
	hw.end_variant()!;
	hw.end_struct()!;
}