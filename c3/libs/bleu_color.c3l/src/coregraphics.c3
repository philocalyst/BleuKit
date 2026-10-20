<*
 The macOS backend: gamma tables through CoreGraphics, `CGSetDisplayTransferByTable`, one call per
 active display.

 The contract (read from the objc2-core-graphics 0.3.2 bindings generated from the Apple SDK headers,
 `CGDirectDisplay.rs` and `CGError.rs`, and cross-checked against Lunar's use of the same call, as
 docs/research/display.md section 2.8 records): the table is three arrays of `size` CGGammaValue
 floats, 0.0 to 1.0; `CGError` is an i32, 0 for success; `CGGetDisplayTransferByTable` reports the
 table's sample count and `CGDisplayRestoreColorSyncSettings` restores every display's ColorSync
 curve. A display's table is captured when the backend opens, and restored when the display is
 released, so that the display gets back exactly the table it had.

 COMPILED ONLY: type-checked for macOS, never run.
*>
module bleu::color::coregraphics @feat(DARWIN) @link("CoreGraphics.framework");
import bleu::availability, bleu::color, bleu::color::engine, bleu::color::ramp, bleu::error, bleu::rt::worker, bleu::unit, std::core::mem, std::math, std::time, std::core::string;

// Source: objc2-core-graphics 0.3.2, src/generated/CGDirectDisplay.rs (the SDK header's signatures).
extern fn int getActiveDisplayList(uint max, uint* displays, uint* count) @cname("CGGetActiveDisplayList");
extern fn uint displayIsBuiltin(uint display) @cname("CGDisplayIsBuiltin");
extern fn int setDisplayTransferByTable(uint display, uint size, float* red, float* green, float* blue) @cname("CGSetDisplayTransferByTable");
extern fn int getDisplayTransferByTable(uint display, uint capacity, float* red, float* green, float* blue, uint* samples) @cname("CGGetDisplayTransferByTable");
extern fn void displayRestoreColorSyncSettings() @cname("CGDisplayRestoreColorSyncSettings");

<* Most displays the backend lists. CoreGraphics reports the active ones; more are ignored. *>
const uint MAX_DISPLAYS = 32;

<* Entries a transfer table is read with: the largest table this backend captures. *>
const uint MAX_SAMPLES = 256;

<* One active display: its id, its name and the table it had when the backend opened. *>
struct CgDisplay
{
	uint id;
	String name;
	usz size;
	float[] original;
}

<* The backend's state, from `create` until `destroy`. *>
struct CgRamp
{
	Allocator allocator;
	Duration tick;
	CgDisplay[] displays;
}

const Driver DRIVER = {
	.info = { "coregraphics", "CGSetDisplayTransferByTable on each active display", 20 },
	.id = Backend.COREGRAPHICS,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// CoreGraphics is part of every macOS session: the probe only confirms that there is a backend to try.
fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	return alloc::new(allocator, CgRamp, { .allocator = allocator, .tick = options.tick });
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, (CgRamp*)state);
}

fn void run(void* state, ColorHub* hub, Host{Command}* host)
{
	CgRamp* cg = (CgRamp*)state;
	defer cg.free_displays();
	if (catch cg.open_displays()) return;
	Platform platform = { .context = cg, .write = &write_ramp, .release = &release_ramp };
	Engine engine;
	cg.start_engine(hub, &platform, &engine);
	defer engine.free();
	serve_timed(&engine, host, cg.tick);
	cg.restore_colorsync(&engine);
}

<*
 List the active displays and capture each one's table. A display whose table cannot be read, or
 has fewer than two entries, is left out.

 @return? error::BACKEND_FAILURE : "CGGetActiveDisplayList failed"
*>
fn void? CgRamp.open_displays(&self)
{
	uint[MAX_DISPLAYS] ids;
	uint count = 0;
	if (getActiveDisplayList(MAX_DISPLAYS, &ids, &count) != 0)
	{
		return error::raise(error::BACKEND_FAILURE, error::Domain.MACH, 0, "CGGetActiveDisplayList failed")~;
	}
	self.displays = alloc::new_array(self.allocator, CgDisplay, (sz)count);
	usz kept = 0;
	for (usz i = 0; i < count; i++)
	{
		float[MAX_SAMPLES] red;
		float[MAX_SAMPLES] green;
		float[MAX_SAMPLES] blue;
		uint samples = 0;
		if (getDisplayTransferByTable(ids[i], MAX_SAMPLES, &red, &green, &blue, &samples) != 0 || samples < 2) continue;
		usz size = (usz)samples;
		CgDisplay* slot = &self.displays[kept];
		slot.id = ids[i];
		slot.size = size;
		slot.name = displayIsBuiltin(ids[i]) != 0 ? "Built-in display".copy(self.allocator) : "External display".copy(self.allocator);
		slot.original = alloc::new_array(self.allocator, float, 3 * size);
		mem::copy(&slot.original[0], &red, size * float::size);
		mem::copy(&slot.original[size], &green, size * float::size);
		mem::copy(&slot.original[2 * size], &blue, size * float::size);
		kept++;
	}
	self.displays = self.displays[0:kept];
}

// Free the displays and their names and captured tables.
fn void CgRamp.free_displays(&self)
{
	foreach (&slot : self.displays)
	{
		alloc::free(self.allocator, slot.name.ptr);
		alloc::free(self.allocator, slot.original.ptr);
	}
	if (self.displays.len > 0) alloc::free(self.allocator, self.displays.ptr);
	self.displays = { };
}

// The engine over the displays: each one's ramp size is the sample count it reported.
fn void CgRamp.start_engine(&self, ColorHub* hub, Platform* platform, Engine* engine)
{
	@pool()
	{
		Output[] outputs = alloc::new_array(tmem, Output, self.displays.len);
		foreach (i, slot : self.displays)
		{
			outputs[i] = {
				.id = string::tformat("cg-%d", slot.id),
				.name = slot.name,
				.control = {
					.gamma_supported = true,
					.availability = availability::YES,
					.size = (uint)slot.size,
					.brightness = (Level)1.0f,
				},
			};
		}
		engine.init(self.allocator, hub, platform, outputs);
	};
}

// Engine callback: write `ramp` (three tables of the display's size) to display `index`.
fn void? write_ramp(void* context, usz index, float[] ramp)
{
	CgRamp* cg       = (CgRamp*)context;
	CgDisplay* slot  = &cg.displays[index];
	usz size         = slot.size;
	int status       = setDisplayTransferByTable(slot.id, (uint)size, &ramp[0], &ramp[size], &ramp[2 * size]);
	if (status != 0)
	{
		return error::raise(error::BACKEND_FAILURE, error::Domain.MACH, status, "CGSetDisplayTransferByTable failed on %s", slot.name)~;
	}
}

// Engine callback: give display `index` back the table it had when the backend opened.
fn void release_ramp(void* context, usz index)
{
	CgRamp* cg      = (CgRamp*)context;
	CgDisplay* slot = &cg.displays[index];
	usz size        = slot.size;
	// Restoring a table cannot be reported usefully: the display keeps the table it has.
	if (setDisplayTransferByTable(slot.id, (uint)size, &slot.original[0], &slot.original[size], &slot.original[2 * size]) != 0) {}
}

<*
 At shutdown, after each display's table is restored: when any display held a ramp, ask
 CoreGraphics to re-apply every display's ColorSync curve, not only the ones this backend changed.
*>
fn void CgRamp.restore_colorsync(&self, Engine* engine)
{
	for (usz i = 0; i < self.displays.len; i++)
	{
		if (!engine.displays[i].output.control.active) continue;
		release_ramp(self, i);
		displayRestoreColorSyncSettings();
		return;
	}
}
