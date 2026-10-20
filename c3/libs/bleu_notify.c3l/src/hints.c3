<*
 The `a{sv}` hints of a Notify call, read straight from the wire.

 Every value is read with the D-Bus reader, which checks each type against its
 signature, so nothing here trusts an application's bytes. A hint this centre
 does not know is skipped. A hint it knows with the wrong type is skipped and
 counted in `Hints.ignored`; the notification is still shown. An `image-data`
 that is not a valid image (wrong bits per sample, a size or stride that does
 not fit, too little data, larger than `MAX_IMAGE_BYTES`) is dropped the same way.
 Strings and pixels are copied into the allocator given, so the message can go.
*>
module bleu::notify::hints;
import std::collections::maybe, bleu::error, bleu::unit, bleu::dbus::marshal, bleu::notify, bleu::notify::text;

const String IMAGE_TYPE = "(iiibiiay)";
const int IMAGE_BITS_PER_SAMPLE = 8;
const int MAX_ROW_BYTES = 4 * notify::MAX_IMAGE_DIMENSION; // RGBA at the largest width

<* What the Notify call's hints say, copied out of the message. *>
struct Hints
{
	notify::Urgency urgency;
	String category;
	String desktop_entry;
	String image_path;
	bool has_image;
	notify::Image image;
	Maybe{Level} progress;
	String stack_tag;
	bool resident;
	bool transient;
	bool suppress_sound;
	String sound_name;
	String sound_file;
	uint ignored; // hints skipped because their name was known but their type was not
	// Precedence of the alternatives: a higher rank replaces a lower one, whatever the order on the wire.
	int image_rank;
	int path_rank;
	int tag_rank;
}

<*
 Read the hints of one Notify call into `out`. Always leaves the reader after the
 hints, so the caller can read the arguments that follow.

 @param allocator : "Allocator for the copied strings and pixels"
 @param [&inout] out : "Overwritten"
 @return? error::PROTOCOL : "The reader's data does not hold a valid a{sv}"
*>
fn void? decode(Reader* r, Allocator allocator, Hints* out)
{
	*out = { .urgency = notify::Urgency.NORMAL };
	r.begin_array()!;
	while (r.has_more())
	{
		r.begin_dict_entry()!;
		String key  = r.read_string()!;
		String type = r.begin_variant()!;
		apply(out, allocator, r, key, type)!;
		r.end_variant()!;
		r.end_dict_entry()!;
	}
	r.end_array()!;
}

// Read one hint's value (exactly one value, always) and keep it if it is a hint this centre acts on.
fn void? apply(Hints* out, Allocator allocator, Reader* r, String key, String type)
{
	if (key == "urgency") return take_urgency(out, r, type);
	if (key == "category") return take_text(out, &out.category, r, type, notify::MAX_CATEGORY, allocator);
	if (key == "desktop-entry") return take_text(out, &out.desktop_entry, r, type, notify::MAX_DESKTOP_ENTRY, allocator);
	if (key == "sound-file") return take_text(out, &out.sound_file, r, type, notify::MAX_SOUND, allocator);
	if (key == "sound-name") return take_text(out, &out.sound_name, r, type, notify::MAX_SOUND, allocator);
	if (key == "resident") return take_flag(out, r, type, &out.resident);
	if (key == "transient") return take_flag(out, r, type, &out.transient);
	if (key == "suppress-sound") return take_flag(out, r, type, &out.suppress_sound);
	if (key == "value") return take_progress(out, r, type);
	if (key == "image-path") return take_path(out, r, type, allocator, 2);
	if (key == "image_path") return take_path(out, r, type, allocator, 1);
	if (key == "image-data") return take_image(out, r, type, allocator, 3);
	if (key == "image_data") return take_image(out, r, type, allocator, 2);
	if (key == "icon_data") return take_image(out, r, type, allocator, 1);
	int rank = tag_rank(key);
	if (rank > 0) return take_tag(out, r, type, allocator, rank);
	// Not a hint of this centre: the specification says to ignore it.
	return r.skip_value();
}

// Skip a value whose type is wrong for the hint it names.
fn void? mismatch(Hints* out, Reader* r)
{
	out.ignored++;
	return r.skip_value();
}

fn void? take_urgency(Hints* out, Reader* r, String type)
{
	if (type != "y") return mismatch(out, r);
	char level = r.read_byte()!;
	// 0 low, 2 critical; anything else is treated as normal, as the spec's default.
	out.urgency = level == 0 ? notify::Urgency.LOW : (level == 2 ? notify::Urgency.CRITICAL : notify::Urgency.NORMAL);
}

fn void? take_flag(Hints* out, Reader* r, String type, bool* slot)
{
	if (type != "b") return mismatch(out, r);
	*slot = r.read_bool()!;
}

fn void? take_text(Hints* out, String* slot, Reader* r, String type, usz max, Allocator allocator)
{
	if (type != "s") return mismatch(out, r);
	String v = r.read_string()!;
	*slot = text::truncate(v, max).copy(allocator);
}

fn void? take_path(Hints* out, Reader* r, String type, Allocator allocator, int rank)
{
	if (type != "s") return mismatch(out, r);
	String v = r.read_string()!;
	if (rank <= out.path_rank) return;
	out.path_rank = rank;
	out.image_path = text::truncate(v, notify::MAX_IMAGE_PATH).copy(allocator);
}

// `value` is an INT32 (the common form) or a UINT32 (dunst reads both); percent, clamped to a level.
fn void? take_progress(Hints* out, Reader* r, String type)
{
	if (type == "i")
	{
		int v = r.read_i32()!;
		out.progress = maybe::value(unit::from_percent((float)v));
	}
	else if (type == "u")
	{
		uint v = r.read_u32()!;
		out.progress = maybe::value(unit::from_percent((float)v));
	}
	else
	{
		return mismatch(out, r);
	}
}

// Stack tags, most specific first. Zero means the key is not one of them.
fn int tag_rank(String key)
{
	if (key == "x-canonical-private-synchronous") return 4;
	if (key == "private-synchronous") return 3;
	if (key == "synchronous") return 2;
	if (key == "x-dunst-stack-tag") return 1;
	return 0;
}

fn void? take_tag(Hints* out, Reader* r, String type, Allocator allocator, int rank)
{
	if (type != "s") return mismatch(out, r);
	String v = r.read_string()!;
	if (rank <= out.tag_rank) return;
	out.tag_rank = rank;
	out.stack_tag = text::truncate(v, notify::MAX_STACK_TAG).copy(allocator);
}

// The image in `(iiibiiay)`. A valid image replaces a lower-ranked one; the rest is read and dropped.
fn void? take_image(Hints* out, Reader* r, String type, Allocator allocator, int rank)
{
	if (type != IMAGE_TYPE) return mismatch(out, r);
	r.begin_struct()!;
	int width      = r.read_i32()!;
	int height     = r.read_i32()!;
	int rowstride  = r.read_i32()!;
	bool has_alpha = r.read_bool()!;
	int bits       = r.read_i32()!;
	int channels   = r.read_i32()!;
	usz needed     = image_bytes(width, height, rowstride, has_alpha, bits, channels);
	if (needed == 0 || rank <= out.image_rank)
	{
		r.skip_value()!;
		r.end_struct()!;
		if (needed == 0) out.ignored++;
		return;
	}
	char[] pixels = alloc::new_array(allocator, char, (sz)needed);
	usz count = 0;
	r.begin_array()!;
	while (r.has_more())
	{
		char b = r.read_byte()!;
		if (count < needed) pixels[count] = b;
		count++;
	}
	r.end_array()!;
	r.end_struct()!;
	if (count < needed)
	{
		out.ignored++;
		return;
	}
	out.image = { .width = width, .height = height, .rowstride = rowstride, .has_alpha = has_alpha, .channels = channels, .pixels = pixels };
	out.has_image = true;
	out.image_rank = rank;
}

<*
 The number of pixel bytes a valid image needs, or 0 when the header is not valid.
 Rows are `rowstride` bytes apart; the last row needs only its pixels.
*>
fn usz image_bytes(int width, int height, int rowstride, bool has_alpha, int bits, int channels)
{
	if (bits != IMAGE_BITS_PER_SAMPLE) return 0;
	if (width <= 0 || height <= 0) return 0;
	if (width > notify::MAX_IMAGE_DIMENSION || height > notify::MAX_IMAGE_DIMENSION) return 0;
	if (channels != (has_alpha ? 4 : 3)) return 0;
	if (rowstride < width * channels || rowstride > MAX_ROW_BYTES) return 0;
	usz needed = (usz)rowstride * (usz)(height - 1) + (usz)(width * channels);
	if (needed > notify::MAX_IMAGE_BYTES) return 0;
	return needed;
}
