<*
 The DDC/CI conversation with one display: timing, retries, and the operations
 a backend exposes (get, set, verified set, save, capabilities).

 Timing and retry rules come from the open-source implementations, which agree
 with the DDC/CI 1.1 and MCCS 2.2a timings (see `Options` for each value and
 its sources). The session never reads a clock: every wait is a call to the
 injected `Sleeper`, so tests see the exact sequence of delays.
*>
module bleu::ddc::session;
import std::time, bleu::error, bleu::ddc::packet, bleu::ddc::vcp, bleu::ddc::capabilities, bleu::ddc::transport;
import std::collections::list;

<* Bytes of a Get VCP Feature Reply: destination, length, 8 payload bytes, checksum. *>
const usz GET_VCP_FRAME_BYTES  = 11;
<* Bytes read for a capabilities fragment: the largest reply frame. *>
const usz FRAGMENT_FRAME_BYTES = packet::MAX_REPLY_PAYLOAD + 3;
<* Bytes of the largest request frame this module sends. *>
const usz REQUEST_WIRE_BYTES   = packet::MAX_PAYLOAD + 3;

<*
 Timing and retry policy. `default_options` gives the values, and each field
 says where its number comes from.
*>
struct Options
{
	// Physical attempts per operation (the first try included). MonitorControl
	// `Arm64DDC.swift` retries 4 times, so 5 attempts; Lunar `DDC.c` uses 10.
	uint max_tries;
	// Null replies tolerated before the operation is refused as UNSUPPORTED.
	// ddcutil `ddc_packet_io.c` (`ddcrc_null_response_max = 3`). ddcutil notes that
	// some monitors answer unsupported codes with a null message.
	uint max_null_replies;
	// Wait between writing a request and reading its reply. DDC/CI 4.3 says at
	// least 40 ms (ddcutil `tuned_sleep.c`, SE_WRITE_TO_READ). The `ddc` crate
	// `commands.rs` uses 40 ms for Get VCP, and MonitorControl waits 50 ms.
	Duration write_to_read;
	// Wait after a command, before the next. The `ddc` crate `commands.rs` uses
	// 50 ms ("DELAY_COMMAND_MS"); ddcutil `tuned_sleep.c` says "at least 50ms".
	Duration between_commands;
	// Wait before a retry. The `ddc` crate `DELAY_COMMAND_FAILED_MS` is 40 ms, and
	// Lunar `DDCReadIntel` sleeps 40 ms before each retry (DDC/CI 4.4.1).
	Duration retry_delay;
	// Wait after Save Current Settings. The `ddc` crate `SaveCurrentSettings` uses
	// 200 ms. ddcutil `tuned_sleep.c` says "The host should wait at least 200 ms
	// before sending the next message to the display".
	Duration save_settle;
	// Wait between a Set VCP and the read-back in `set_vcp_verified`. No source
	// gives a figure: this is this library's choice, chosen to exceed the command
	// gap so that a monitor that applies changes late is given a chance.
	Duration verify_settle;
	// How long a read may wait for the first byte of a reply. No source gives a
	// figure; the reply itself is due after `write_to_read`, so this is a margin.
	Duration reply_timeout;
	// Largest capabilities string accepted, in bytes. Not from a source: a limit
	// against a monitor that never ends its string.
	usz max_capabilities;
}

<* The policy the table in `Options` describes. *>
fn Options default_options()
{
	return {
		.max_tries = 5,
		.max_null_replies = 3,
		.write_to_read = time::ms(40),
		.between_commands = time::ms(50),
		.retry_delay = time::ms(40),
		.save_settle = time::ms(200),
		.verify_settle = time::ms(50),
		.reply_timeout = time::ms(100),
		.max_capabilities = 8192,
	};
}

<*
 Counters a backend can surface. Every field only grows.

 `operations`: Public operations that completed
 `attempts`: Physical writes or write/read exchanges, first tries included
 `retries`: Attempts after the first of an operation
 `null_replies`: Null messages received
 `protocol_errors`: Replies that failed framing, checksum, opcode, or matching
 `io_errors`: Writes or reads the transport refused
 `duplicate_fragments`: Capabilities fragments repeated by the monitor
 `unsupported`: Operations refused as UNSUPPORTED (result 0x01 or repeated nulls)
 `verify_mismatches`: Read-backs that did not match the value written
 `failures`: Writes or exchanges that gave up after `max_tries`
*>
struct Statistics
{
	ulong operations;
	ulong attempts;
	ulong retries;
	ulong null_replies;
	ulong protocol_errors;
	ulong io_errors;
	ulong duplicate_fragments;
	ulong unsupported;
	ulong verify_mismatches;
	ulong failures;
}

<*
 The value of one VCP feature as the monitor reports it.

 `momentary`: True when the feature is momentary (a one-shot action)
 `current`: Present value
 `maximum`: Maximum value; 0 for non-continuous features
*>
struct Reading
{
	VcpCode code;
	bool momentary;
	ushort current;
	ushort maximum;
}

<*
 A session with one display. It is not thread-safe: a backend drives it from one
 thread (the service's worker).

 `transport`: The byte channel to the display
 `sleeper`: How the session waits
 `options`: Timing and retry policy
 `stats`: Counters, readable at any time
*>
struct Session
{
	Transport transport;
	Sleeper sleeper;
	Options options;
	Statistics stats;
}

<* A session over `transport`, with `options` and the given way of waiting. *>
fn Session open(Transport transport, Sleeper sleeper, Options options)
{
	return { .transport = transport, .sleeper = sleeper, .options = options };
}

<*
 Read one feature.

 @return? error::UNSUPPORTED : "The monitor does not support `code`, or keeps answering with null messages"
 @return? error::PROTOCOL : "Every attempt got a malformed reply"
 @return? error::BACKEND_FAILURE : "The transport failed on every attempt"
*>
fn Reading? Session.get_vcp(&self, VcpCode code)
{
	char[GET_VCP_FRAME_BYTES] buffer;
	Reply reply = self.exchange(packet::get_vcp(code), packet::ReplyKind.GET_VCP, code, buffer[..])!;
	self.complete(self.options.between_commands);
	return {
		.code = code,
		.momentary = reply.momentary,
		.current = reply.current,
		.maximum = reply.maximum,
	};
}

<*
 Set one feature. A Set VCP has no reply, so only the write can fail.

 @return? error::BACKEND_FAILURE : "The transport refused the write on every attempt"
*>
fn void? Session.set_vcp(&self, VcpCode code, ushort value)
{
	char[REQUEST_WIRE_BYTES] wire;
	usz n = packet::set_vcp(code, value).encode_i2c(wire[..])!!;
	self.send(wire[0:n])!;
	self.complete(self.options.between_commands);
}

<*
 Set one feature, then read it back and check that it holds the value written.

 A monitor may apply a change late, which is why the read-back waits
 `verify_settle` first. A monitor that clamps the value to its range will not
 match, and reports that as a failure (the caller compares `current` with the
 value it wanted if clamping is expected).

 @return "The value the monitor reports after the write"
 @return? error::BACKEND_FAILURE : "The read-back differs from the value written"
*>
fn ushort? Session.set_vcp_verified(&self, VcpCode code, ushort value)
{
	self.set_vcp(code, value)!;
	self.pause(self.options.verify_settle);
	Reading read = self.get_vcp(code)!;
	if (read.current != value)
	{
		self.stats.verify_mismatches++;
		return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.INTERNAL,
			0,
			"VCP 0x%02x reads back %d after writing %d",
			(char)code,
			read.current,
			value
		)~;
	}
	return read.current;
}

<* Save Current Settings to the monitor's memory. *>
fn void? Session.save_settings(&self)
{
	char[REQUEST_WIRE_BYTES] wire;
	usz n = packet::save_settings().encode_i2c(wire[..])!!;
	self.send(wire[0:n])!;
	self.complete(self.options.save_settle);
}

<*
 Read the capabilities string, fragment by fragment, and parse it.

 @param allocator : "Owns the result"
 @return? error::PROTOCOL : "The monitor kept sending malformed or out-of-order fragments"
 @return? error::OUT_OF_RANGE : "The string is longer than `Options.max_capabilities`"
 @return? error::UNSUPPORTED : "The monitor refused the request"
*>
fn Capabilities? Session.read_capabilities(&self, Allocator allocator)
{
	Capabilities result;
	@pool()
	{
		List{char} text;
		text.tinit();
		self.read_fragments(&text)!;
		self.stats.operations++;
		result = capabilities::parse((String)text.array_view(), allocator);
	};
	return result;
}

// Read fragments from offset 0 until the monitor sends an empty one.
fn void? Session.read_fragments(&self, List{char}* text) @private
{
	usz offset   = 0;
	uint repeats = 0;
	char[FRAGMENT_FRAME_BYTES] buffer;
	while (true)
	{
		Reply reply = self.exchange(
			packet::capabilities_request((ushort)offset),
			packet::ReplyKind.CAPABILITIES_FRAGMENT,
			(VcpCode)0,
			buffer[..]
		)!;
		self.pause(self.options.between_commands);
		if (reply.offset != (ushort)offset)
		{
			// A fragment for an earlier offset is a repeat. Ask again for this one.
			if (reply.offset < offset)
			{
				self.stats.duplicate_fragments++;
				if (++repeats > self.options.max_tries)
				{
					return error::raise(
						error::PROTOCOL,
						error::Domain.INTERNAL,
						0,
						"monitor repeated earlier fragments %d times",
						repeats
					)~;
				}
				continue;
			}
			return error::raise(
				error::PROTOCOL,
				error::Domain.INTERNAL,
				0,
				"capabilities fragment at offset %d, expected %d",
				reply.offset,
				offset
			)~;
		}
		if (reply.fragment_len == 0) return;
		if (offset + reply.fragment_len > self.options.max_capabilities)
		{
			return error::raise(
				error::OUT_OF_RANGE,
				error::Domain.INTERNAL,
				0,
				"capabilities string exceeds %d bytes",
				self.options.max_capabilities
			)~;
		}
		text.push_all(reply.fragment[0:reply.fragment_len]);
		offset += reply.fragment_len;
	}
}

<*
 Send a request and read its reply, retrying as the policy says.

 A null message counts as a try, and after `max_null_replies` of them the request
 is refused as UNSUPPORTED. A malformed reply and a transport failure are retried.
 An UNSUPPORTED reply from the monitor is final and is not retried.
*>
fn Reply? Session.exchange(&self, Request request, packet::ReplyKind expected, VcpCode code, char[] buffer) @private
{
	char[REQUEST_WIRE_BYTES] wire;
	usz n      = request.encode_i2c(wire[..])!!;
	fault last = error::BACKEND_FAILURE;
	uint nulls = 0;
	for (uint attempt = 1; attempt <= self.options.max_tries; attempt++)
	{
		if (attempt > 1) self.retry();
		self.stats.attempts++;
		Reply? outcome = self.attempt(wire[0:n], expected, code, buffer);
		if (catch failure = outcome)
		{
			if (failure == error::UNSUPPORTED)
			{
				self.stats.unsupported++;
				return failure~;
			}
			if (failure == error::PROTOCOL)
			{
				self.stats.protocol_errors++;
			}
			else
			{
				self.stats.io_errors++;
			}
			last = failure;
			continue;
		}
		if (outcome.kind != packet::ReplyKind.NULL_MESSAGE) return outcome;
		self.stats.null_replies++;
		if (++nulls > self.options.max_null_replies)
		{
			self.stats.unsupported++;
			return error::raise(
				error::UNSUPPORTED,
				error::Domain.INTERNAL,
				0,
				"monitor answered %d times with a null message",
				nulls
			)~;
		}
		last = error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "null message");
	}
	self.stats.failures++;
	return last~;
}

// Send a request without expecting a reply, retrying a refused write.
fn void? Session.send(&self, char[] wire) @private
{
	fault last = error::BACKEND_FAILURE;
	for (uint attempt = 1; attempt <= self.options.max_tries; attempt++)
	{
		if (attempt > 1) self.retry();
		self.stats.attempts++;
		if (catch failure = self.transport.write(wire))
		{
			self.stats.io_errors++;
			last = failure;
			continue;
		}
		return;
	}
	self.stats.failures++;
	return last~;
}

// One write, the wait for the reply, one read, and a check of what came back.
fn Reply? Session.attempt(&self, char[] wire, packet::ReplyKind expected, VcpCode code, char[] buffer) @private
{
	self.transport.write(wire)!;
	self.pause(self.read_wait());
	usz received = self.transport.read(buffer, self.options.reply_timeout)!;
	if (received == 0) return TIMEOUT~;
	Reply reply = packet::parse_reply(buffer[0:received])!;
	if (reply.kind == packet::ReplyKind.NULL_MESSAGE) return reply;
	if (reply.kind != expected)
	{
		return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			0,
			"reply of kind %d where %d was expected",
			(char)reply.kind,
			(char)expected
		)~;
	}
	if (expected == packet::ReplyKind.GET_VCP && reply.code != code)
	{
		return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			0,
			"reply for VCP 0x%02x where 0x%02x was asked",
			(char)reply.code,
			(char)code
		)~;
	}
	return reply;
}

// The wait between a write and its reply: the policy, or the transport's own
// minimum if that is longer.
fn Duration Session.read_wait(&self) @private
{
	Duration transport_minimum = self.transport.min_interval_after_write();
	return transport_minimum > self.options.write_to_read ? transport_minimum : self.options.write_to_read;
}

// The wait before a retry, counted as a retry.
fn void Session.retry(&self) @private
{
	self.stats.retries++;
	self.pause(self.options.retry_delay);
}

// A public operation finished: count it, then honour the gap that follows it.
fn void Session.complete(&self, Duration gap) @private
{
	self.stats.operations++;
	self.pause(gap);
}

fn void Session.pause(&self, Duration duration) @private
{
	if (duration > time::DURATION_ZERO) self.sleeper.sleep(self.sleeper.context, duration);
}