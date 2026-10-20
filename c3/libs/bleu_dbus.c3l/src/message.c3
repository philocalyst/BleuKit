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
	UNKNOWN,       // a type code this implementation does not know: ignored
}

<* Header flag: the sender does not want a reply (flags bit 0x1). *>
const char FLAG_NO_REPLY_EXPECTED = 0x1;

<* Header flag: the bus must not start a service to deliver this (flags bit 0x2). *>
const char FLAG_NO_AUTO_START = 0x2;

<* Header flag: the caller accepts interactive authorization (flags bit 0x4). *>
const char FLAG_ALLOW_INTERACTIVE_AUTHORIZATION = 0x4;

// Header field codes (spec "Header Fields").
const char FIELD_PATH = 1;
const char FIELD_INTERFACE = 2;
const char FIELD_MEMBER = 3;
const char FIELD_ERROR_NAME = 4;
const char FIELD_REPLY_SERIAL = 5;
const char FIELD_DESTINATION = 6;
const char FIELD_SENDER = 7;
const char FIELD_SIGNATURE = 8;
const char FIELD_UNIX_FDS = 9;

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
	if (!names::is_object_path(path) || !names::is_interface(iface) || !names::is_member(member)) return error::INVALID_ARGUMENT~;
	if (destination.len > 0 && !names::is_bus_name(destination)) return error::INVALID_ARGUMENT~;
	Message* m = create(parent, SIGNAL);
	m.flags = FLAG_NO_REPLY_EXPECTED;
	m.path = path.copy(&m.storage);
	m.interface_name = iface.copy(&m.storage);
	m.member = member.copy(&m.storage);
	m.destination = destination.copy(&m.storage);
	return m;
}

<*
 A METHOD_RETURN answering `call`. Its body is written with `body_writer`.
*>
fn Message*? method_return(Allocator parent, Message* call)
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
