<*
 EDID 1.3/1.4 parser: the identity, size, timing and extension blocks of a
 display, and a fingerprint that matches a platform's monitor to its DDC bus.

 Layout (EDID 1.4 base block, 128 bytes; the offsets are the ones in the Linux
 kernel's `include/drm/drm_edid.h` `struct edid`, and the `edid` crate's
 `parse_header`/`parse_display`/`parse_detailed_timing` agree with them):

 0..7    header 00 FF FF FF FF FF FF 00
 8..9    manufacturer PNP id, big-endian, three 5-bit letters
 10..11  product code, little-endian
 12..15  serial number, little-endian (0 when not set)
 16      week of manufacture
 17      year of manufacture, minus 1990
 18..19  EDID version and revision
 20      video input definition (bit 7: digital)
 21..22  maximum image size, cm (horizontal, vertical)
 23      gamma, as gamma * 100 - 100
 24      features (bit 1: first detailed timing is the preferred timing)
 54,72,90,108  four 18-byte descriptors
 126     number of extension blocks
 127     checksum: all 128 bytes sum to 0 mod 256

 An extension block is 128 bytes with a tag in byte 0 (0x02 for CEA-861, 0x70
 for DisplayID) and its own checksum in byte 127.
*>
module bleu::ddc::edid;
import std::core::mem, bleu::error;

<* Bytes in a base block or an extension block. *>
const usz BLOCK_BYTES           = 128;
<* Offset of each of the four descriptors in the base block. *>
const usz[4] DESCRIPTOR_OFFSETS = { 54, 72, 90, 108 };
<* The fixed header every base block starts with. *>
const char[8] EDID_HEADER       = { 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
<* Bytes in one descriptor. *>
const usz DESCRIPTOR_BYTES      = 18;

<* Byte offset of the extension count in the base block. *>
const usz EXTENSION_COUNT_OFFSET = 126;
<* Tag of a CEA-861 extension block (kernel `drm_edid.h`, `CEA_EXT`). *>
const char EXTENSION_CEA         = 0x02;
<* Tag of a DisplayID extension block (kernel `drm_edid.h`, `DISPLAYID_EXT`). *>
const char EXTENSION_DISPLAYID   = 0x70;

<* Descriptor tag in byte 3 of a non-timing descriptor: display name (kernel `EDID_DETAIL_MONITOR_NAME`). *>
const char DESCRIPTOR_NAME   = 0xFC;
<* Descriptor tag: serial number text (kernel `EDID_DETAIL_MONITOR_SERIAL`). *>
const char DESCRIPTOR_SERIAL = 0xFF;

<* Features byte bit: the first detailed timing is the preferred one (kernel `DRM_EDID_FEATURE_PREFERRED_TIMING`). *>
const char FEATURE_PREFERRED_TIMING = 0x02;
<* Video input bit: digital (kernel `DRM_EDID_INPUT_DIGITAL`). *>
const char INPUT_DIGITAL            = 0x80;

<* Year of manufacture is stored as an offset from this. *>
const uint YEAR_BASE = 1990;

<* FNV-1a 64-bit offset basis and prime (the `fnv` crate: `FnvHasher` and its test vector). *>
const ulong FNV_OFFSET_BASIS = 0xcbf29ce484222325;
const ulong FNV_PRIME        = 0x100000001b3;

<*
 A detailed timing descriptor: a mode the display can show. The pixel clock is
 in kHz; the active and blanking counts are in pixels and lines.
*>
struct Timing
{
	uint pixel_clock_khz;
	ushort horizontal_active;
	ushort horizontal_blank;
	ushort vertical_active;
	ushort vertical_blank;
}

<*
 The parsed identity and capabilities of one display.

 The manufacturer is a 3-letter PNP id (for example "SAM"); `vendor_code` keeps
 its 16-bit form, which is what platform APIs report as the vendor number.
 `serial_number` is 0 when the block does not set one, and `serial_text` is the
 serial descriptor (0xFF), empty when absent. `name` is the display name (0xFC),
 empty when absent. `has_preferred_timing` says whether `preferred` is set.
 `extension_tags` lists the tag of each extension block in order.
*>
struct Edid
{
	char[3] vendor;
	ushort vendor_code;
	ushort product_code;
	uint serial_number;
	String serial_text;
	String name;
	char week;
	uint year;
	char version;
	char revision;
	bool digital;
	char width_cm;
	char height_cm;
	double gamma;
	bool has_preferred_timing;
	Timing preferred;
	char[] extension_tags;
}

<*
 Parse an EDID block, with its extension blocks when `data` includes them.

 The base block must have the right header and checksum, the extension count
 must fit in `data`, and each extension must have a valid checksum.

 @param data : "The EDID bytes, at least one 128-byte block"
 @param allocator : "Owns the strings and the extension tag list"
 @return? error::PROTOCOL : "Wrong length, header, checksum, or a truncated extension"
*>
fn Edid? parse(char[] data, Allocator allocator)
{
	if (data.len < BLOCK_BYTES)
	{
		return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			0,
			"EDID is %d bytes, at least %d are needed",
			data.len,
			BLOCK_BYTES
		)~;
	}
	for (usz i = 0; i < EDID_HEADER.len; i++)
	{
		if (data[i] == EDID_HEADER[i]) continue;
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "EDID header is not 00 FF FF FF FF FF FF 00")~;
	}
	if (sum(data[0:BLOCK_BYTES]) != 0)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "EDID base block checksum is wrong")~;
	}
	usz extensions = (usz)data[EXTENSION_COUNT_OFFSET];
	if ((usz)data.len < BLOCK_BYTES * (extensions + 1))
	{
		return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			0,
			"EDID declares %d extension blocks but holds only %d bytes",
			extensions,
			data.len
		)~;
	}
	char[] tags = alloc::new_array(allocator, char, (sz)extensions);
	for (usz i = 0; i < extensions; i++)
	{
		char[] block = data[BLOCK_BYTES * (i + 1):BLOCK_BYTES];
		if (sum(block) != 0)
		{
			return error::raise(
				error::PROTOCOL,
				error::Domain.INTERNAL,
				0,
				"EDID extension %d checksum is wrong",
				i + 1
			)~;
		}
		tags[i] = block[0];
	}
	return identify(data, tags, allocator);
}

// The fields of a checked base block.
fn Edid identify(char[] data, char[] tags, Allocator allocator) @private
{
	uint manufacturer = (byte_at(data, 8) << 8) | byte_at(data, 9);
	Edid edid = {
		.vendor = {
			letter((manufacturer >> 10) & 0x1F),
			letter((manufacturer >> 5) & 0x1F),
			letter(manufacturer & 0x1F),
		},
		.vendor_code = (ushort)manufacturer,
		.product_code = (ushort)(byte_at(data, 10) | (byte_at(data, 11) << 8)),
		.serial_number = byte_at(
			data,
			12
		) | (byte_at(data, 13) << 8) | (byte_at(data, 14) << 16) | (byte_at(data, 15) << 24),
		.week = data[16],
		.year = YEAR_BASE + byte_at(data, 17),
		.version = data[18],
		.revision = data[19],
		.digital = (data[20] & INPUT_DIGITAL) != 0,
		.width_cm = data[21],
		.height_cm = data[22],
		.gamma = ((double)data[23] + 100.0) / 100.0,
		.has_preferred_timing = (data[24] & FEATURE_PREFERRED_TIMING) != 0,
		.extension_tags = tags,
	};
	bool timing_seen = false;
	for (usz i = 0; i < DESCRIPTOR_OFFSETS.len; i++)
	{
		char[] d = data[DESCRIPTOR_OFFSETS[i]:DESCRIPTOR_BYTES];
		if (d[0] != 0 || d[1] != 0)
		{
			// A timing descriptor. The first one is the preferred timing.
			if (!timing_seen) edid.preferred = timing(d);
			timing_seen = true;
			continue;
		}
		if (d[3] == DESCRIPTOR_NAME) edid.name = descriptor_text(d, allocator);
		if (d[3] == DESCRIPTOR_SERIAL) edid.serial_text = descriptor_text(d, allocator);
	}
	return edid;
}

// Decode one detailed timing descriptor. The high nibbles of bytes 4 and 7 carry the
// upper bits of the active and blanking counts (edid crate `parse_detailed_timing`).
fn Timing timing(char[] d) @private
{
	return {
		.pixel_clock_khz = (byte_at(d, 0) | (byte_at(d, 1) << 8)) * 10,
		.horizontal_active = (ushort)(byte_at(d, 2) | ((byte_at(d, 4) >> 4) << 8)),
		.horizontal_blank = (ushort)(byte_at(d, 3) | ((byte_at(d, 4) & 0x0F) << 8)),
		.vertical_active = (ushort)(byte_at(d, 5) | ((byte_at(d, 7) >> 4) << 8)),
		.vertical_blank = (ushort)(byte_at(d, 6) | ((byte_at(d, 7) & 0x0F) << 8)),
	};
}

// The 13 text bytes of a descriptor: text ends at a line feed, then spaces pad it.
// Only printable ASCII is kept, so the result is always valid UTF-8.
fn String descriptor_text(char[] d, Allocator allocator) @private
{
	char[13] raw;
	usz kept = 0;
	for (usz i = 5; i < 18; i++)
	{
		if (d[i] == 0x0A) break;
		if (d[i] >= 0x20 && d[i] < 0x7F) raw[kept++] = d[i];
	}
	while (kept > 0 && raw[kept - 1] == ' ') kept--;
	String text = (String)raw[0:kept];
	return text.copy(allocator);
}

// Decode one letter of the PNP id: 1 is 'A', 26 is 'Z'. Values outside that range
// are kept as the letter they map to, as the kernel does.
fn char letter(uint value) @private => (char)('@' + value);

// A byte of `d` as a wide integer, for the shifts that assemble multi-byte fields.
fn uint byte_at(char[] d, usz i) @private => (uint)d[i];

fn uint sum(char[] block) @private
{
	uint total = 0;
	foreach (b : block) total += b;
	return total & 0xFF;
}

<*
 A stable 64-bit identity for a display, for matching a platform's monitor (a
 CoreGraphics display, a Windows `MONITORINFOEX`) to the DDC bus it answers on.

 The hash covers the manufacturer, product code, serial number (only when it is
 non-zero) and display name. Platforms expose the same vendor, product and
 serial, so the hash can be computed on either side and compared.

 Hazard: many panels leave the serial number at 0, and two units of one model
 with the same name then have the same fingerprint. Lunar `DDC.c` notes this
 ("SN is zero in lots of cases, so duplicate-monitors can confuse us"). The
 fingerprint identifies a model in that case, not a unit. Use the bus (or the
 port) as the tie-breaker.
*>
fn ulong Edid.fingerprint(&self)
{
	ulong hash = FNV_OFFSET_BASIS;
	hash = fold(hash, self.vendor[..]);
	char[2] product = { (char)self.product_code, (char)(self.product_code >> 8) };
	hash = fold(hash, product[..]);
	if (self.serial_number != 0)
	{
		char[4] serial = {
			(char)self.serial_number,
			(char)(self.serial_number >> 8),
			(char)(self.serial_number >> 16),
			(char)(self.serial_number >> 24),
		};
		hash = fold(hash, serial[..]);
	}
	return fold(hash, self.name);
}

// FNV-1a over `bytes`, starting from `hash`.
fn ulong fold(ulong hash, char[] bytes) @private
{
	foreach (b : bytes)
	{
		hash ^= b;
		hash *= FNV_PRIME;
	}
	return hash;
}