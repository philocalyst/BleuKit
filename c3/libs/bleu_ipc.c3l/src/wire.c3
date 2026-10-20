<*
 The byte-level wire format of the DMS IPC protocol, as dankgo's `ipc` package
 speaks it: one JSON value per line, UTF-8, each line ended by `\n`.

 This module is the only place that writes envelopes. It has no state and no
 I/O, so every rule in it is unit-tested directly. The envelopes are:

 handshake   {"apiVersion":N,"capabilities":[...]}      (no id)
 result      {"id":N,"result":<json>}
 error       {"id":N,"error":"<text>"}
 service     {"id":N,"result":{"service":"<name>","data":<json>}}

 `id` is left out when it is 0: dankgo declares it `int` with `omitempty`, so
 Go drops a zero id. Sources, with line numbers, are in docs/research/bleu_ipc.md.
*>
module bleu::ipc::wire @feat(POSIX);
import bleu::error;

<*
 Largest request line the server accepts by default, in bytes, not counting its
 newline. DMS sets 64 MiB (core/internal/server/server.go:931); dankgo's own
 default is 1 MiB (ipc/server.go:21).
*>
const usz DEFAULT_MAX_LINE = 64 * 1024 * 1024;

<* Bytes read from a socket per receive call. dankgo's read buffer (ipc/server.go:163). *>
const usz READ_CHUNK = 64 * 1024;

// Lower-case hexadecimal digits, for the `\u00XX` escapes.
const String HEX_DIGITS = "0123456789abcdef";

<*
 A growable byte buffer that one frame is built in. Allocation failure aborts,
 as everywhere in C3, so these methods do not return excuses.
*>
struct Writer
{
	Allocator allocator;
	char[] buffer;
	usz len;
}

<*
 Start an empty writer.

 @param allocator : "Allocator for the buffer; the finished frame belongs to it too"
 @param capacity : "Initial size in bytes; the buffer grows when needed"
*>
fn void Writer.init(&self, Allocator allocator, usz capacity)
{
	self.allocator = allocator;
	self.buffer = alloc::new_array(allocator, char, (sz)max_of(capacity, 16));
	self.len = 0;
}

// Make room for `extra` more bytes, doubling the buffer when it is too small.
fn void reserve(Writer* w, usz extra) @private
{
	usz needed = w.len + extra;
	if (needed <= (usz)w.buffer.len) return;
	usz size      = max_of(needed, (usz)w.buffer.len * 2);
	char[] bigger = alloc::new_array(w.allocator, char, (sz)size);
	if (w.len > 0) mem::copy(bigger.ptr, w.buffer.ptr, (sz)w.len);
	alloc::free(w.allocator, w.buffer.ptr);
	w.buffer = bigger;
}

<* Append raw bytes. *>
fn void Writer.put(&self, String text)
{
	if (text.len == 0) return;
	reserve(self, (usz)text.len);
	mem::copy(&self.buffer[(sz)self.len], text.ptr, (sz)text.len);
	self.len += (usz)text.len;
}

<* Append one byte. *>
fn void Writer.put_char(&self, char c)
{
	reserve(self, 1);
	self.buffer[(sz)self.len] = c;
	self.len++;
}

<* Append an integer in decimal, with a minus sign when negative. *>
fn void Writer.put_long(&self, long value)
{
	char[20] digits;
	sz count        = 0;
	ulong magnitude = value < 0 ? (ulong)(-(value + 1)) + 1 : (ulong)value;
	do
	{
		digits[count++] = (char)('0' + (int)(magnitude % 10));
		magnitude /= 10;
	} while (magnitude > 0);
	if (value < 0) self.put_char('-');
	while (count > 0) self.put_char(digits[--count]);
}

<*
 Append `text` as the body of a JSON string: quotes and backslashes are escaped,
 control bytes become `\n`-style or `\u00XX` escapes. Other bytes pass through,
 which is correct for UTF-8 input (the caller has checked it).
*>
fn void Writer.put_escaped(&self, String text)
{
	for (sz i = 0; i < text.len; i++)
	{
		char c = text[i];
		switch (c)
		{
			case '"':
				self.put("\\\"");
			case '\\':
				self.put("\\\\");
			case '\n':
				self.put("\\n");
			case '\r':
				self.put("\\r");
			case '\t':
				self.put("\\t");
			case '\b':
				self.put("\\b");
			case '\f':
				self.put("\\f");
			default:
				if (c < 0x20)
				{
					self.put("\\u00");
					self.put_char(HEX_DIGITS[(sz)(c >> 4)]);
					self.put_char(HEX_DIGITS[(sz)(c & 0xF)]);
				}
				else
				{
					self.put_char(c);
				}
		}
	}
}

<*
 Hand over the bytes written so far. The caller owns them and releases them with
 `alloc::free(allocator, frame.ptr)`. The writer is empty afterwards.
*>
fn String Writer.finish(&self)
{
	String frame = (String)self.buffer[0:self.len];
	self.buffer = { };
	self.len = 0;
	return frame;
}

<* Largest of two sizes. *>
fn usz max_of(usz a, usz b) @inline => a > b ? a : b;

// Write `{"id":N,`, or just `{` when the id is 0 (dankgo's omitempty).
fn void put_head(Writer* w, long id) @private
{
	w.put("{");
	if (id != 0)
	{
		w.put("\"id\":");
		w.put_long(id);
		w.put(",");
	}
}

<*
 Whether `text` can be written as one frame. A frame ends at the first newline,
 so a JSON value containing a line break would split into two frames.

 @return "true when the text is non-empty and holds no newline"
*>
fn bool is_single_line(String text)
{
	if (text.len == 0) return false;
	for (sz i = 0; i < text.len; i++)
	{
		if (text[i] == '\n') return false;
	}
	return true;
}

<*
 Whether `bytes` is well-formed UTF-8 (RFC 3629): no overlong forms, no UTF-16
 surrogates, nothing above U+10FFFF. The server checks every request line with
 this before parsing it.
*>
fn bool valid_utf8(String bytes)
{
	sz i = 0;
	while (i < bytes.len)
	{
		char lead = bytes[i];
		if (lead < 0x80)
		{
			i++;
			continue;
		}
		sz width         = 0;
		char low_second  = 0x80;
		char high_second = 0xBF;
		if (lead >= 0xC2 && lead <= 0xDF)
		{
			width = 2;
		}
		else if (lead >= 0xE0 && lead <= 0xEF)
		{
			width = 3;
			if (lead == 0xE0) low_second = 0xA0;
			if (lead == 0xED) high_second = 0x9F;
		}
		else if (lead >= 0xF0 && lead <= 0xF4)
		{
			width = 4;
			if (lead == 0xF0) low_second = 0x90;
			if (lead == 0xF4) high_second = 0x8F;
		}
		else
		{
			return false;
		}
		if (i + width > bytes.len) return false;
		char second = bytes[i + 1];
		if (second < low_second || second > high_second) return false;
		for (sz k = 2; k < width; k++)
		{
			char continuation = bytes[i + k];
			if (continuation < 0x80 || continuation > 0xBF) return false;
		}
		i += width;
	}
	return true;
}

<*
 A `result` frame: `{"id":N,"result":<result_json>}` followed by a newline.

 @param result_json : "One JSON value, written as it is"
 @return "The frame, owned by the caller (release with `alloc::free(allocator, frame.ptr)`)"
*>
fn String result_frame(Allocator allocator, long id, String result_json)
{
	Writer w;
	w.init(allocator, result_json.len + 32);
	put_head(&w, id);
	w.put("\"result\":");
	w.put(result_json);
	w.put("}\n");
	return w.finish();
}

<*
 An `error` frame: `{"id":N,"error":"<message>"}` followed by a newline. The
 message is escaped, so any text is safe.

 @return "The frame, owned by the caller"
*>
fn String error_frame(Allocator allocator, long id, String message)
{
	Writer w;
	w.init(allocator, message.len + 32);
	put_head(&w, id);
	w.put("\"error\":\"");
	w.put_escaped(message);
	w.put("\"}\n");
	return w.finish();
}

<*
 A subscription frame: `{"id":N,"result":{"service":"<service>","data":<data>}}`
 followed by a newline. This is the frame DMS sends for every service value.

 @param data : "The service's state, one JSON value, written as it is"
 @return "The frame, owned by the caller"
*>
fn String service_frame(Allocator allocator, long id, String service, String data)
{
	Writer w;
	w.init(allocator, service.len + data.len + 48);
	put_head(&w, id);
	w.put("\"result\":{\"service\":\"");
	w.put_escaped(service);
	w.put("\",\"data\":");
	w.put(data);
	w.put("}}\n");
	return w.finish();
}

<*
 The handshake line a client reads first: the `ServerInfo` value followed by a
 newline (dankgo ipc/server.go:143-153).

 @param capabilities : "Capability names; each is escaped"
 @return "The line, owned by the caller"
*>
fn String handshake_frame(Allocator allocator, int api_version, String[] capabilities)
{
	Writer w;
	w.init(allocator, 64);
	put_server_info(&w, api_version, capabilities);
	w.put("\n");
	return w.finish();
}

<*
 A request line: `{"id":N,"method":"<method>","params":<params_json>}` followed by
 a newline. The client uses it; dankgo's client sends the same shape.

 @param params_json : "One JSON value, written as it is; `null` for none"
 @return "The line, owned by the caller"
*>
fn String request_frame(Allocator allocator, long id, String method, String params_json)
{
	Writer w;
	w.init(allocator, method.len + params_json.len + 48);
	w.put("{\"id\":");
	w.put_long(id);
	w.put(",\"method\":\"");
	w.put_escaped(method);
	w.put("\",\"params\":");
	w.put(params_json);
	w.put("}\n");
	return w.finish();
}

<*
 The `ServerInfo` value: `{"apiVersion":N,"capabilities":["a","b"]}`, with no
 newline. It is the handshake line (minus the newline) and the `data` of the
 `server` service.

 @param capabilities : "Capability names; each is escaped"
 @return "The JSON value, owned by the caller"
*>
fn String server_info(Allocator allocator, int api_version, String[] capabilities)
{
	Writer w;
	w.init(allocator, 64);
	put_server_info(&w, api_version, capabilities);
	return w.finish();
}

// Write the `ServerInfo` object into `w`.
fn void put_server_info(Writer* w, int api_version, String[] capabilities) @private
{
	w.put("{\"apiVersion\":");
	w.put_long(api_version);
	w.put(",\"capabilities\":[");
	for (sz i = 0; i < capabilities.len; i++)
	{
		if (i > 0) w.put(",");
		w.put("\"");
		w.put_escaped(capabilities[i]);
		w.put("\"");
	}
	w.put("]}");
}