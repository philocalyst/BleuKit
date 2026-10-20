<*
 The StatusNotifierItem properties: their names and types, and how each one is read into an
 item. The types are the specification's (KDE's `org.kde.StatusNotifierItem.xml`). Reading uses
 the Reader directly, so an icon's bytes go straight into its pixel buffer, with no value tree.
*>
module bleu::tray::sni @feat(LINUX);
import std::collections::list, bleu::dbus::marshal, bleu::error, bleu::tray, bleu::tray::convert;

// The property's name on the item.
fn String property_name(Prop prop)
{
	switch (prop)
	{
		case ID: return "Id";
		case CATEGORY: return "Category";
		case TITLE: return "Title";
		case STATUS: return "Status";
		case ICON_NAME: return "IconName";
		case ICON_PIXMAP: return "IconPixmap";
		case ATTENTION_NAME: return "AttentionIconName";
		case ATTENTION_PIXMAP: return "AttentionIconPixmap";
		case OVERLAY_NAME: return "OverlayIconName";
		case OVERLAY_PIXMAP: return "OverlayIconPixmap";
		case TOOLTIP: return "ToolTip";
		case THEME_PATH: return "IconThemePath";
		case MENU_PATH: return "Menu";
		case ITEM_IS_MENU: return "ItemIsMenu";
	}
}

// The D-Bus type of the property, as a complete signature. `a(iiay)` is ARGB32 pixmaps.
fn String expected_signature(Prop prop)
{
	if (prop == ICON_PIXMAP || prop == ATTENTION_PIXMAP || prop == OVERLAY_PIXMAP) return "a(iiay)";
	if (prop == TOOLTIP) return "(sa(iiay)ss)";
	if (prop == MENU_PATH) return "o";
	if (prop == ITEM_IS_MENU) return "b";
	return "s";
}

// Empty the item fields that `prop` fills, so a property that cannot be read leaves nothing stale.
fn void clear_prop(ItemRecord* r, Prop prop)
{
	switch (prop)
	{
		case ID: r.item.item_id = "";
		case CATEGORY: r.item.category = UNKNOWN;
		case TITLE: r.item.title = "";
		case STATUS: r.item.status = PASSIVE;
		case ICON_NAME: r.item.icon_name = "";
		case ICON_PIXMAP: r.item.icon_pixmaps = { };
		case ATTENTION_NAME: r.item.attention_icon_name = "";
		case ATTENTION_PIXMAP: r.item.attention_icon_pixmaps = { };
		case OVERLAY_NAME: r.item.overlay_icon_name = "";
		case OVERLAY_PIXMAP: r.item.overlay_icon_pixmaps = { };
		case TOOLTIP:
			r.item.has_tooltip = false;
			r.item.tooltip = { };
		case THEME_PATH: r.item.icon_theme_path = "";
		case MENU_PATH: r.item.menu_path = "";
		case ITEM_IS_MENU: r.item.item_is_menu = false;
	}
}

<*
 Read the value of `prop` (the reader is inside its variant) into the record, with its
 strings and pixmaps allocated in `a`.

 @return? error::PROTOCOL : "The value does not match the property's type"
*>
fn void? parse_prop(Reader* rd, Prop prop, ItemRecord* r, Allocator a)
{
	switch (prop)
	{
		case ID: r.item.item_id = convert::copy_text(rd.read_string()!, a);
		case CATEGORY: r.item.category = convert::category_from(rd.read_string()!);
		case TITLE: r.item.title = convert::copy_text(rd.read_string()!, a);
		case STATUS: r.item.status = convert::status_from(rd.read_string()!);
		case ICON_NAME: r.item.icon_name = convert::copy_text(rd.read_string()!, a);
		case ICON_PIXMAP: r.item.icon_pixmaps = read_pixmaps(rd, a)!;
		case ATTENTION_NAME: r.item.attention_icon_name = convert::copy_text(rd.read_string()!, a);
		case ATTENTION_PIXMAP: r.item.attention_icon_pixmaps = read_pixmaps(rd, a)!;
		case OVERLAY_NAME: r.item.overlay_icon_name = convert::copy_text(rd.read_string()!, a);
		case OVERLAY_PIXMAP: r.item.overlay_icon_pixmaps = read_pixmaps(rd, a)!;
		case TOOLTIP:
			r.item.tooltip = read_tooltip(rd, a)!;
			r.item.has_tooltip = true;
		case THEME_PATH: r.item.icon_theme_path = convert::copy_text(rd.read_string()!, a);
		case MENU_PATH: r.item.menu_path = convert::copy_text(rd.read_object_path()!, a);
		case ITEM_IS_MENU: r.item.item_is_menu = rd.read_bool()!;
	}
}

<*
 Read an `a(iiay)` array: each element is a width, a height and ARGB32 bytes. Elements whose
 dimensions do not fit are skipped; a byte count that disagrees with the dimensions is a protocol
 error, since the reader cannot resynchronise after it.
*>
fn tray::Pixmap[]? read_pixmaps(Reader* rd, Allocator a)
{
	rd.begin_array()!;
	List{tray::Pixmap} pixmaps;
	pixmaps.init(a, 2);
	while (rd.has_more())
	{
		rd.begin_struct()!;
		int width  = rd.read_i32()!;
		int height = rd.read_i32()!;
		if (!convert::dims_fit(width, height))
		{
			rd.skip_value()!;
		}
		else
		{
			pixmaps.push(read_pixmap_bytes(rd, width, height, a)!);
		}
		rd.end_struct()!;
	}
	rd.end_array()!;
	return pixmaps.array_view();
}

// The `ay` of one pixmap, copied into an RGBA buffer of exactly width * height * 4 bytes.
fn tray::Pixmap? read_pixmap_bytes(Reader* rd, int width, int height, Allocator a)
{
	usz capacity  = (usz)width * (usz)height * convert::PIXEL_BYTES;
	char[] pixels = alloc::new_array(a, char, (sz)capacity);
	rd.begin_array()!;
	usz count = 0;
	while (rd.has_more())
	{
		char byte = rd.read_byte()!;
		if (count == capacity) return error::PROTOCOL~;
		pixels[count++] = byte;
	}
	rd.end_array()!;
	if (count != capacity) return error::PROTOCOL~;
	convert::argb_to_rgba(pixels, width, height)!;
	return { .width = width, .height = height, .pixels = (String)pixels };
}

// `(sa(iiay)ss)`: icon name, icon pixmaps, title, description.
fn tray::Tooltip? read_tooltip(Reader* rd, Allocator a)
{
	rd.begin_struct()!;
	String icon_name     = convert::copy_text(rd.read_string()!, a);
	tray::Pixmap[] icons = read_pixmaps(rd, a)!;
	String title         = convert::copy_text(rd.read_string()!, a);
	String description   = convert::copy_text(rd.read_string()!, a);
	rd.end_struct()!;
	return { .icon_name = icon_name, .icon_pixmaps = icons, .title = title, .description = description };
}