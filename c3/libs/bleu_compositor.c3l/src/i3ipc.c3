<*
 The i3-ipc binary framing used by sway and i3.

 A message is a 6-byte magic "i3-ipc", a 32-bit payload length, a 32-bit type,
 then the payload. Length and type are in native byte order (i3 docs/ipc,
 "The i3 IPC protocol"; swayipc-types 2.0.3 `command.rs` encodes with
 `to_ne_bytes`, swayipc 3.0.3 `common.rs` decodes with `from_ne_bytes`). An
 event is a message whose type has bit 31 set; the low bits are the event type.
*>
module bleu::compositor::i3ipc;
import bleu::error, bleu::compositor::wire;

<* The magic that opens every message. *>
const String MAGIC = "i3-ipc";
<* Bytes in the magic. *>
const usz MAGIC_SIZE = 6;
<* Bytes before the payload: magic, length, type. *>
const usz HEADER_SIZE = 14;
<* Bit 31 of the type marks an event. *>
const uint EVENT_BIT = 0x80000000;

<* Request types (i3 docs/ipc "Message types"). Values as in sway 1.x-2.x. *>
constset MessageType : uint
{
	RUN_COMMAND = 0,
	GET_WORKSPACES = 1,
	SUBSCRIBE = 2,
	GET_OUTPUTS = 3,
	GET_TREE = 4,
	GET_VERSION = 7,
	GET_INPUTS = 100,
}

<*
 Event types with bit 31 cleared (i3 docs/ipc "Available events"; sway adds 20
 and 21, swayipc-types 2.0.3 `error/event.rs` decodes the same numbers).
*>
constset EventType : uint
{
	WORKSPACE = 0,
	OUTPUT = 1,
	MODE = 2,
	WINDOW = 3,
	BARCONFIG_UPDATE = 4,
	BINDING = 5,
	SHUTDOWN = 6,
	TICK = 7,
	BAR_STATE_UPDATE = 20,
	INPUT = 21,
}

<* A decoded header. `length` is the payload size in bytes. *>
struct Header
{
	uint type;
	uint length;
}

<*
 Build one message: the header followed by `payload`.

 @param allocator : "Allocator for the message bytes"
 @return "The complete message"
*>
fn char[] encode(Allocator allocator, uint type, String payload)
{
	usz total = HEADER_SIZE + payload.len;
	char[] frame = alloc::new_array(allocator, char, (sz)total);
	mem::copy(frame.ptr, MAGIC.ptr, (sz)MAGIC_SIZE);
	uint length = (uint)payload.len;
	mem::copy(frame.ptr + MAGIC_SIZE, &length, 4);
	mem::copy(frame.ptr + MAGIC_SIZE + 4, &type, 4);
	if (payload.len > 0) mem::copy(frame.ptr + HEADER_SIZE, payload.ptr, payload.len);
	return frame;
}

<*
 Decode the 14 header bytes.

 @param bytes : "At least HEADER_SIZE bytes, starting with the header"
 @require bytes.len >= HEADER_SIZE : "A header is HEADER_SIZE bytes"
 @return? error::PROTOCOL : "The magic is wrong: this is not an i3-ipc peer"
*>
fn Header? decode_header(String bytes)
{
	if (!bytes.starts_with(MAGIC)) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "i3-ipc magic is missing")~;
	uint length;
	uint type;
	mem::copy(&length, bytes.ptr + MAGIC_SIZE, 4);
	mem::copy(&type, bytes.ptr + MAGIC_SIZE + 4, 4);
	return { .type = type, .length = length };
}

<* True when a header's type has the event bit set. *>
fn bool Header.is_event(self) @inline => (self.type & EVENT_BIT) != 0;

<* The event type with bit 31 cleared. *>
fn uint Header.event_type(self) @inline => self.type & ~EVENT_BIT;

<*
 The name a shell knows an event type by, as used in `RawEvent.name`.

 @return "The name, or \"unknown\" for an event type this library does not know"
*>
fn String event_name(uint event_type)
{
	switch ((EventType)event_type)
	{
		case EventType.WORKSPACE: return "workspace";
		case EventType.OUTPUT: return "output";
		case EventType.MODE: return "mode";
		case EventType.WINDOW: return "window";
		case EventType.BARCONFIG_UPDATE: return "barconfig_update";
		case EventType.BINDING: return "binding";
		case EventType.SHUTDOWN: return "shutdown";
		case EventType.TICK: return "tick";
		case EventType.BAR_STATE_UPDATE: return "bar_state_update";
		case EventType.INPUT: return "input";
		default: return "unknown";
	}
}

<* One complete message: its header and its payload (a view into the buffer). *>
struct Frame
{
	Header header;
	String payload;
}

<*
 Take the next complete message from `buffer`, consuming it.

 @return "The message; its payload is valid until the buffer is fed again"
 @return? NOT_FOUND : "The message is not complete yet"
 @return? error::PROTOCOL : "The magic is wrong, or the message is longer than the buffer"
*>
fn Frame? take_frame(wire::Buffer* buffer)
{
	String head = buffer.peek_exact(HEADER_SIZE)!;
	Header header = decode_header(head)!;
	check_length(header, buffer.capacity)!;
	String whole = buffer.peek_exact(HEADER_SIZE + header.length)!;
	buffer.consume(HEADER_SIZE + header.length);
	return { .header = header, .payload = whole[HEADER_SIZE : header.length] };
}

<*
 Reject a payload length that cannot fit the buffer the reader uses for it.

 @param capacity : "Size of the reader's buffer"
 @return? error::PROTOCOL : "The header announces more than the buffer holds"
*>
fn void? check_length(Header header, usz capacity)
{
	if ((usz)header.length + HEADER_SIZE > capacity)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "i3-ipc message of %d bytes exceeds %d", header.length, capacity)~;
	}
}
