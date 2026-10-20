<*
 Pure rules of the tray: pixmap layout, menu labels, watcher registrations and the text
 of enumerated properties. No I/O, so every host runs the tests in `convert_test.c3`.
*>
module bleu::tray::convert;
import bleu::error, bleu::dbus::names, bleu::tray;

<* Largest edge of an icon we accept, in pixels. Bounds the memory one icon can take. *>
const int MAX_ICON_EDGE = 512;

<* Bytes of one ARGB32 or RGBA pixel. *>
const usz PIXEL_BYTES = 4;

<* The object path an item uses when its registration names only the bus. *>
const String DEFAULT_ITEM_PATH = "/StatusNotifierItem";

<* Whether both edges of an icon are in 1..MAX_ICON_EDGE. *>
fn bool dims_fit(int width, int height)
{
	return width > 0 && height > 0 && width <= MAX_ICON_EDGE && height <= MAX_ICON_EDGE;
}

<*
 Whether an icon of this size has exactly the bytes it claims: `dims_fit` and
 `length == width * height * 4`. Read the height from the height field, never the width.
*>
fn bool pixmap_fits(int width, int height, usz length)
{
	if (!dims_fit(width, height)) return false;
	return length == (usz)width * (usz)height * PIXEL_BYTES;
}

<*
 Turn ARGB32 pixels in network byte order (alpha first, as the specification's `a(iiay)` sends
 them) into RGBA in place. The bytes are one pixel after another, so the width does not matter
 for the layout, only for the size check.

 @param data : "width * height * 4 bytes, converted in place"
 @return? error::INVALID_ARGUMENT : "The size does not match the dimensions"
*>
fn void? argb_to_rgba(char[] data, int width, int height)
{
	if (!pixmap_fits(width, height, data.len)) return error::INVALID_ARGUMENT~;
	for (usz i = 0; i < data.len; i += PIXEL_BYTES)
	{
		char alpha = data[i];
		data[i] = data[i + 1];
		data[i + 1] = data[i + 2];
		data[i + 2] = data[i + 3];
		data[i + 3] = alpha;
	}
}

<*
 A menu label with DBusMenu's mnemonic markers removed: "__" is one literal underscore, and a single
 "_" marks the next character as the mnemonic, so it is dropped. The result is allocated in `allocator`.
*>
fn String mnemonic_free(String raw, Allocator allocator)
{
	if (raw.len == 0) return "";
	char[] out = alloc::new_array(allocator, char, raw.len);
	usz n      = 0;
	usz i      = 0;
	while (i < raw.len)
	{
		if (raw[i] != '_')
		{
			out[n++] = raw[i++];
			continue;
		}
		if (i + 1 < raw.len && raw[i + 1] == '_')
		{
			out[n++] = '_';
			i += 2;
			continue;
		}
		i++;
	}
	return (String)out[0:n];
}

<* A registration split into the bus name and the object path it names. Both are slices of the inputs. *>
struct Registration
{
	String bus_name;
	String object_path;
}

<*
 Split the argument of RegisterStatusNotifierItem. Three forms are in use:
 - "bus-name": the path is `/StatusNotifierItem`;
 - "bus-name/path" (Electron, since 43.4.1, and the form the watcher stores): split at the first "/";
 - "/path" alone: the bus name is the caller, `sender`.

 @return? error::INVALID_ARGUMENT : "Not a valid bus name or object path"
*>
fn Registration? parse_registration(String argument, String sender)
{
	if (argument.len == 0) return error::INVALID_ARGUMENT~;
	Registration r;
	if (argument[0] == '/')
	{
		r.bus_name = sender;
		r.object_path = argument;
	}
	else
	{
		sz slash = argument.index_of_char('/') ?? -1;
		if (slash < 0)
		{
			r.bus_name = argument;
			r.object_path = DEFAULT_ITEM_PATH;
		}
		else
		{
			r.bus_name = argument[0..slash - 1];
			r.object_path = argument[slash..argument.len - 1];
		}
	}
	if (!names::is_bus_name(r.bus_name) || !names::is_object_path(r.object_path)) return error::INVALID_ARGUMENT~;
	return r;
}

<*
 The identifier an item is known by: the bus name and the object path, joined. The watcher stores
 items in this form, so it is what `RegisteredStatusNotifierItems` returns.
*>
fn String item_id(Registration r, Allocator allocator)
{
	sz bus_bytes = r.bus_name.len;
	char[] joined = alloc::new_array(allocator, char, bus_bytes + r.object_path.len);
	mem::copy(&joined[0], r.bus_name.ptr, (usz)bus_bytes);
	mem::copy(&joined[bus_bytes], r.object_path.ptr, (usz)r.object_path.len);
	return (String)joined;
}

<* The status from its `Status` text. Unknown text reads as PASSIVE. *>
fn tray::Status status_from(String text)
{
	if (text == "Active") return ACTIVE;
	if (text == "NeedsAttention") return NEEDS_ATTENTION;
	return PASSIVE;
}

<* The category from its `Category` text. *>
fn tray::Category category_from(String text)
{
	if (text == "ApplicationStatus") return APPLICATION;
	if (text == "Communications") return COMMUNICATIONS;
	if (text == "SystemServices") return SYSTEM_SERVICES;
	if (text == "Hardware") return HARDWARE;
	return UNKNOWN;
}

<* The check or radio mark from `toggle-type`. Unknown text means no mark. *>
fn tray::Toggle toggle_from(String text)
{
	if (text == "checkmark") return CHECKMARK;
	if (text == "radio") return RADIO;
	return NONE;
}

<* The state from `toggle-state`: 0 is off, 1 on, anything else (including the default -1) indeterminate. *>
fn tray::ToggleState toggle_state_from(int value)
{
	if (value == 0) return OFF;
	if (value == 1) return ON;
	return INDETERMINATE;
}

<* The urgency from `disposition`. Unknown text reads as NORMAL. *>
fn tray::Disposition disposition_from(String text)
{
	if (text == "informative") return INFORMATIVE;
	if (text == "warning") return WARNING;
	if (text == "alert") return ALERT;
	return NORMAL;
}

<* A copy of `text` in `allocator`; "" (no allocation) when empty. *>
fn String copy_text(String text, Allocator allocator)
{
	if (text.len == 0) return "";
	return text.copy(allocator);
}

<* Copy our own item, its menu entries included, into `allocator`. *>
fn tray::OwnItem copy_own(tray::OwnItem own, Allocator allocator)
{
	tray::OwnMenuEntry[] menu = {};
	if (own.menu.len > 0)
	{
		menu = alloc::new_array(allocator, tray::OwnMenuEntry, own.menu.len);
		foreach (i, &entry : own.menu)
		{
			menu[i] = { .id = entry.id, .label = copy_text(entry.label, allocator), .is_separator = entry.is_separator, .enabled = entry.enabled };
		}
	}
	return { .title = copy_text(own.title, allocator), .icon = copy_text(own.icon, allocator), .menu = menu };
}

<*
 A menu label as Win32 shows it: a single "_" (DBusMenu's mnemonic marker) becomes "&", a literal
 "_" written "__" stays "_", and a literal "&" is doubled so it is not a mnemonic. The result is in `allocator`.
*>
fn String win32_label(String raw, Allocator allocator)
{
	if (raw.len == 0) return "";
	usz capacity = (usz)raw.len * 2;
	char[] out = alloc::new_array(allocator, char, (sz)capacity);
	usz n = 0;
	usz i = 0;
	while (i < raw.len)
	{
		char c = raw[i];
		if (c == '_' && i + 1 < raw.len && raw[i + 1] == '_')
		{
			out[n++] = '_';
			i += 2;
			continue;
		}
		if (c == '_')
		{
			out[n++] = '&';
		}
		else if (c == '&')
		{
			out[n++] = '&';
			out[n++] = '&';
		}
		else
		{
			out[n++] = c;
		}
		i++;
	}
	return (String)out[0:n];
}

<*
 Free what `copy_own` allocated. Empty strings and the empty menu were never allocated (they are
 literals or null), so they are not freed.
*>
fn void free_own(tray::OwnItem own, Allocator allocator)
{
	if (own.title.len > 0) alloc::free(allocator, own.title.ptr);
	if (own.icon.len > 0) alloc::free(allocator, own.icon.ptr);
	for (sz i = 0; i < own.menu.len; i++)
	{
		if (own.menu[i].label.len > 0) alloc::free(allocator, own.menu[i].label.ptr);
	}
	if (own.menu.len > 0) alloc::free(allocator, own.menu.ptr);
}
