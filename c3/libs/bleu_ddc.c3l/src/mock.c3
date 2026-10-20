<*
 A simulated display, the monitor side of DDC/CI, for tests here and in the
 services that use this library.

 `MockMonitor` implements `Transport`, so a `Session` drives it exactly as it
 drives hardware. It keeps a VCP store and a capabilities string, answers
 requests the way a monitor does (a bad checksum gets no answer, an unknown
 code gets result 0x01), and injects faults on request. Every fault is a
 counter, so a test can say "the next two replies are corrupt" and get the same
 behaviour on every run.
*>
module bleu::ddc::mock;
import std::core::mem, std::time, bleu::error, bleu::ddc::packet, bleu::ddc::vcp, bleu::ddc::transport;

<* Number of VCP codes a monitor can hold: one per byte value. *>
const usz VCP_CODES      = 256;
<* Bytes a capabilities fragment carries (the most one reply holds). *>
const usz FRAGMENT_BYTES = packet::MAX_FRAGMENT;

<*
 One feature in the monitor's store.

 A `Set VCP` on a feature with `lag_reads` set takes effect only after that many
 Get VCP replies have been sent, which models a monitor that applies changes late.

 `present`: The monitor implements this code
 `momentary`: Type code 0x01 in replies
 `current`: The value a Get VCP reports
 `maximum`: The maximum a Get VCP reports
*>
struct VcpState
{
	bool present;
	bool momentary;
	ushort current;
	ushort maximum;
	ushort pending_value;
	uint pending_reads;
}

<*
 A monitor with a VCP store, a capabilities string and injectable faults.

 Fault counters are consumed one per affected exchange: `drop_replies` makes the
 next reads return nothing (a timeout), `corrupt_replies` puts a bad checksum on
 the next replies, `null_replies` sends null messages, `duplicate_fragments`
 repeats the previous capabilities fragment, `doubled_leads` puts a second leading
 0x6E on the next replies (the ddcutil quirk), and `fail_writes` refuses writes.

 `capabilities`: The capabilities string the monitor reports, in chunks of 32
 `latency`: The time from a write to its reply, as `min_interval_after_write`
 `lag_reads`: Set VCP takes effect after this many Get VCP replies (0 for at once)
 `saves`: Save Current Settings commands received
 `bad_requests`: Requests dropped because their checksum was wrong
*>
struct MockMonitor (Transport)
{
	VcpState[VCP_CODES] store;
	String capabilities;
	Duration latency;
	uint lag_reads;
	uint saves;
	uint bad_requests;
	uint drop_replies;
	uint corrupt_replies;
	uint null_replies;
	uint duplicate_fragments;
	uint doubled_leads;
	uint fail_writes;
	char[packet::MAX_REPLY_PAYLOAD + 3 + packet::LEADING_DUPLICATE_BYTES] reply;
	usz reply_len;
	bool served_fragment;
	usz last_fragment_offset;
}

<*
 A monitor with nothing implemented, reporting `capabilities` from capabilities requests.
*>
fn MockMonitor new_monitor(String capabilities)
{
	return { .capabilities = capabilities };
}

<*
 Make the monitor implement `code` with the given present and maximum values.

 @param momentary : "Whether the feature is momentary"
*>
fn void MockMonitor.add_feature(&self, VcpCode code, ushort current, ushort maximum, bool momentary = false)
{
	self.store[(char)code] = { .present = true, .momentary = momentary, .current = current, .maximum = maximum };
}

<* The present value of `code`, as the monitor holds it right now. *>
fn ushort MockMonitor.value(&self, VcpCode code) => self.store[(char)code].current;

fn void? MockMonitor.write(&self, char[] bytes) @dynamic
{
	if (self.fail_writes > 0)
	{
		self.fail_writes--;
		return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "mock refuses the write")~;
	}
	self.reply_len = 0;
	self.handle(bytes);
}

fn usz? MockMonitor.read(&self, char[] buffer, Duration timeout) @dynamic
{
	if (self.drop_replies > 0)
	{
		self.drop_replies--;
		self.reply_len = 0;
		return 0;
	}
	usz n = self.reply_len < (usz)buffer.len ? self.reply_len : (usz)buffer.len;
	mem::copy(buffer.ptr, self.reply[..].ptr, (sz)n);
	self.reply_len = 0;
	return n;
}

fn Duration MockMonitor.min_interval_after_write(&self) @dynamic => self.latency;

// Answer one request, if it is well formed. Malformed requests get no answer.
fn void MockMonitor.handle(&self, char[] bytes)
{
	if (bytes.len < 3 || bytes[0] != packet::HOST_SOURCE || (bytes[1] & packet::LENGTH_FLAG) == 0)
	{
		self.bad_requests++;
		return;
	}
	usz n = (usz)(bytes[1] & packet::LENGTH_MASK);
	if (n == 0 || bytes.len != n + 3 || bytes[n + 2] != packet::checksum(packet::WRITE_ADDRESS, bytes[0:n + 2]))
	{
		self.bad_requests++;
		return;
	}
	char[] payload = bytes[2:n];
	switch ((packet::Opcode)payload[0])
	{
		case packet::Opcode.GET_VCP_REQUEST:
			if (n == 2) self.answer_get((char)payload[1]);
		case packet::Opcode.SET_VCP:
			if (n == 4) self.apply_set((char)payload[1], (ushort)(((ushort)payload[2] << 8) | payload[3]));
		case packet::Opcode.SAVE_CURRENT_SETTINGS:
			self.saves++;
		case packet::Opcode.CAPABILITIES_REQUEST:
			if (n == 3) self.answer_fragment((usz)(((usz)payload[1] << 8) | payload[2]));
		default:
			return;
	}
}

// Get VCP Feature: the present state, or result 0x01 for an unknown code. A pending
// Set is applied after the reply that was due before it, so a lagging monitor
// reports the old value first.
fn void MockMonitor.answer_get(&self, char code)
{
	VcpState* st = &self.store[(usz)code];
	// A reply is always the full 8-byte layout; an unknown code carries result 0x01 and zeros.
	char[8] payload;
	payload[0] = (char)packet::Opcode.GET_VCP_REPLY;
	payload[2] = code;
	if (!st.present)
	{
		payload[1] = (char)packet::ResultCode.UNSUPPORTED_VCP;
		self.send_reply(payload[..]);
		return;
	}
	payload[3] = st.momentary ? (char)packet::VcpType.MOMENTARY : (char)packet::VcpType.SET_PARAMETER;
	payload[4] = (char)(st.maximum >> 8);
	payload[5] = (char)(st.maximum & 0xFF);
	payload[6] = (char)(st.current >> 8);
	payload[7] = (char)(st.current & 0xFF);
	self.send_reply(payload[..]);
	if (st.pending_reads > 0)
	{
		st.pending_reads--;
		if (st.pending_reads == 0) st.current = st.pending_value;
	}
}

// Set VCP: unknown codes are ignored, as a monitor ignores what it does not implement.
fn void MockMonitor.apply_set(&self, char code, ushort value)
{
	VcpState* st = &self.store[(usz)code];
	if (!st.present) return;
	if (self.lag_reads == 0)
	{
		st.current = value;
		return;
	}
	st.pending_value = value;
	st.pending_reads = self.lag_reads;
}

// Capabilities Request: the chunk of the string at `offset`, up to a fragment.
// `duplicate_fragments` makes the monitor repeat the previous chunk instead.
fn void MockMonitor.answer_fragment(&self, usz offset)
{
	usz at = offset;
	if (self.duplicate_fragments > 0 && self.served_fragment)
	{
		self.duplicate_fragments--;
		at = self.last_fragment_offset;
	}
	else
	{
		self.served_fragment = true;
		self.last_fragment_offset = offset;
	}
	char[FRAGMENT_BYTES + 3] payload;
	usz length = at < self.capabilities.len ? self.capabilities.len - at : 0;
	if (length > FRAGMENT_BYTES) length = FRAGMENT_BYTES;
	payload[0] = (char)packet::Opcode.CAPABILITIES_REPLY;
	payload[1] = (char)(at >> 8);
	payload[2] = (char)(at & 0xFF);
	for (usz i = 0; i < length; i++) payload[3 + i] = self.capabilities[at + i];
	self.send_reply(payload[0:length + 3]);
}

// Frame a reply and apply the faults that are due: a null message replaces it, and a
// corrupt one has its checksum inverted.
fn void MockMonitor.send_reply(&self, char[] payload)
{
	char[] body = payload;
	if (self.null_replies > 0)
	{
		self.null_replies--;
		body = payload[0:0];
	}
	// The quirk: a second 0x6E in front of the frame, which the reader must skip.
	usz lead = 0;
	if (self.doubled_leads > 0)
	{
		self.doubled_leads--;
		self.reply[0] = packet::WRITE_ADDRESS;
		lead = packet::LEADING_DUPLICATE_BYTES;
	}
	usz n = packet::encode_reply(body, self.reply[lead..])!!;
	if (self.corrupt_replies > 0)
	{
		self.corrupt_replies--;
		self.reply[lead + n - 1] ^= 0xFF;
	}
	self.reply_len = lead + n;
}