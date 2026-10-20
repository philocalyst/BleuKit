<*
 The read-only route: `wl_output` with `xdg-output`, which every Wayland compositor offers. It
 reports the outputs, their modes, scale and place in the desktop, but cannot change them. Used
 when the compositor has no wlr-output-management.
*>
module bleu::display::linux_wayland @feat(LINUX);
import bleu::display, bleu::display::wayland_convert, bleu::wl::proto::wayland, bleu::wl::proto::xdg_output;

// wl_output.mode flag bits, as the protocol numbers them.
const uint WL_MODE_CURRENT = (uint)wayland::WlOutputMode.CURRENT;
const uint WL_MODE_PREFERRED = (uint)wayland::WlOutputMode.PREFERRED;

const wayland::WlOutputListener WL_OUTPUT_LISTENER = {
	.geometry = &on_geometry,
	.mode = &on_mode,
	.done = &on_output_done,
	.scale = &on_scale,
	.name = &on_output_name,
	.description = &on_output_description,
};

const xdg_output::ZxdgOutputV1Listener XDG_OUTPUT_LISTENER = {
	.logical_position = &on_logical_position,
	.logical_size = &on_logical_size,
	.done = &on_xdg_done,
	.name = &on_xdg_name,
	.description = &on_xdg_description,
};

// wl_output.geometry: where the output sits and how big it physically is.
fn void on_geometry(
	void* context,
	wayland::WlOutput* target,
	int x,
	int y,
	int physical_width,
	int physical_height,
	wayland::WlOutputSubpixel subpixel,
	String make,
	String model,
	wayland::WlOutputTransform transform
)
{
	OutputRecord* rec = (OutputRecord*)context;
	rec.x = x;
	rec.y = y;
	rec.physical_width = physical_width;
	rec.physical_height = physical_height;
	rec.transform = transform_from_wire((uint)transform);
	set_text(rec, &rec.make, make);
	set_text(rec, &rec.model, model);
}

// wl_output.mode: one mode; the CURRENT and PREFERRED flags say which it is.
fn void on_mode(void* context, wayland::WlOutput* target, wayland::WlOutputMode flags, int width, int height, int refresh)
{
	OutputRecord* rec = (OutputRecord*)context;
	uint bits = (uint)flags;
	bool current = (bits & WL_MODE_CURRENT) != 0;
	ModeRecord* mode = find_wl_mode(rec, (uint)width, (uint)height, refresh_from_wire(refresh));
	if (!mode) {
		mode = new_mode(rec);
		mode.width = (uint)width;
		mode.height = (uint)height;
		mode.refresh = refresh_from_wire(refresh);
	}
	mode.preferred = (bits & WL_MODE_PREFERRED) != 0;
	if (current) {
		for (usz i = 0; i < rec.modes.len(); i++) rec.modes.get(i).current = false;
	}
	mode.current = current;
}

// wl_output.done: the batch of an output's properties is complete.
fn void on_output_done(void* context, wayland::WlOutput* target)
{
	OutputRecord* rec = (OutputRecord*)context;
	rec.enabled = true;
	rec.session.dirty = true;
}

// wl_output.scale: an integer scale; a fractional one comes from xdg-output's logical size.
fn void on_scale(void* context, wayland::WlOutput* target, int factor)
{
	OutputRecord* rec = (OutputRecord*)context;
	rec.scale = (double)factor;
}

// wl_output.name: the connector name, used as the output id.
fn void on_output_name(void* context, wayland::WlOutput* target, String name)
{
	OutputRecord* rec = (OutputRecord*)context;
	set_text(rec, &rec.name, name);
	refresh_fingerprint(rec);
}

// wl_output.description.
fn void on_output_description(void* context, wayland::WlOutput* target, String description)
{
	OutputRecord* rec = (OutputRecord*)context;
	set_text(rec, &rec.description, description);
}

// xdg_output.logical_position: where the output sits in the compositor's desktop.
fn void on_logical_position(void* context, xdg_output::ZxdgOutputV1* target, int x, int y)
{
	OutputRecord* rec = (OutputRecord*)context;
	rec.x = x;
	rec.y = y;
	rec.session.dirty = true;
}

// xdg_output.logical_size: the size in logical pixels, from which the fractional scale follows.
fn void on_logical_size(void* context, xdg_output::ZxdgOutputV1* target, int width, int height)
{
	OutputRecord* rec = (OutputRecord*)context;
	rec.has_logical_size = true;
	rec.logical_width = (uint)width;
	rec.logical_height = (uint)height;
	rec.session.dirty = true;
}

// xdg_output.done (version 2 and older): the xdg properties are complete.
fn void on_xdg_done(void* context, xdg_output::ZxdgOutputV1* target)
{
	OutputRecord* rec = (OutputRecord*)context;
	rec.session.dirty = true;
}

// xdg_output.name: the name the compositor gives the output, used when wl_output sends none.
fn void on_xdg_name(void* context, xdg_output::ZxdgOutputV1* target, String name)
{
	OutputRecord* rec = (OutputRecord*)context;
	if (rec.name.len == 0) {
		set_text(rec, &rec.name, name);
		refresh_fingerprint(rec);
	}
}

// xdg_output.description.
fn void on_xdg_description(void* context, xdg_output::ZxdgOutputV1* target, String description)
{
	OutputRecord* rec = (OutputRecord*)context;
	if (rec.description.len == 0) set_text(rec, &rec.description, description);
}

// The record's mode with this size and refresh, if it has one.
fn ModeRecord* find_wl_mode(OutputRecord* rec, uint width, uint height, display::RefreshMilliHz refresh) @private
{
	for (usz i = 0; i < rec.modes.len(); i++) {
		ModeRecord* mode = rec.modes.get(i);
		if (mode.width == width && mode.height == height && mode.refresh == refresh) return mode;
	}
	return null;
}

// Append an empty mode to the record and return it.
fn ModeRecord* new_mode(OutputRecord* rec) @private
{
	ModeRecord* mode = alloc::new(rec.allocator, ModeRecord);
	mode.owner = rec;
	rec.modes.push(mode);
	return mode;
}
