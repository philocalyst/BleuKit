<*
 The Windows backend: gamma ramps through `SetDeviceGammaRamp`, one device context per attached
 display (`CreateDCW("DISPLAY", "\\.\DISPLAYn")`).

 The contract, as the Microsoft Learn page for SetDeviceGammaRamp states it (read): the
 ramp is three arrays of 256 WORDs (red, green, blue), each entry a 16-bit value; the function
 "implements heuristics", so a ramp that would make the screen unreadable makes it return TRUE
 without setting the ramp; any application can overwrite the ramp at any time; and the ramp is
 reset on most display events. This backend therefore reads the ramp back after each write, and
 reports a mismatch as a failure rather than trusting the return value.

 The read-back tolerance (256 of 65535, one step of an 8-bit DAC) is an assumption: the page does
 not say how drivers quantise a ramp. It is UNVERIFIED on hardware.

 COMPILED ONLY: type-checked for Windows, never run.
*>
module bleu::color::windows_ramp @feat(WIN32) @link("gdi32");
import bleu::availability, bleu::color, bleu::color::engine, bleu::color::kelvin, bleu::color::ramp, bleu::color::windows_displays, bleu::error, bleu::rt::worker, bleu::unit, std::collections::list, std::math, std::time, std::core::mem;

// Source: Microsoft Learn, CreateDCW, DeleteDC, SetDeviceGammaRamp, GetDeviceGammaRamp (wingdi.h, gdi32).
extern fn void* createDCW(ushort* driver, ushort* device, void* port, void* init) @cname("CreateDCW");
extern fn int deleteDC(void* dc) @cname("DeleteDC");
extern fn int setDeviceGammaRamp(void* dc, void* ramp) @cname("SetDeviceGammaRamp");
extern fn int getDeviceGammaRamp(void* dc, void* ramp) @cname("GetDeviceGammaRamp");

<* `L"DISPLAY"` as UTF-16 with its terminating NUL: the driver name that selects a display device. *>
const ushort[8] WIDE_DISPLAY = { 0x44, 0x49, 0x53, 0x50, 0x4C, 0x41, 0x59, 0x00 };

<* Entries in each channel of a Windows ramp: `SetDeviceGammaRamp` takes three arrays of 256 WORDs. *>
const usz RAMP_SIZE = 256;

<* Words in a whole ramp: three channels. *>
const usz RAMP_WORDS = 3 * RAMP_SIZE;

<* How far a read-back word may differ from the word written: one step of an 8-bit DAC (assumed). *>
const long READBACK_TOLERANCE = 256;

<* One attached display: its device name, its device context, and the ramp it had before this service. *>
struct WinDisplay
{
	String name;
	void* dc;
	bool has_original;
	ushort[RAMP_WORDS] original;
	ushort[RAMP_WORDS] words;
}

<* The backend's state, from `create` until `destroy`. *>
struct WinRamp
{
	Allocator allocator;
	Duration tick;
	WinDisplay[] displays;
	ushort[RAMP_WORDS] identity;
}

const Driver DRIVER = {
	.info = { "win32-ramp", "SetDeviceGammaRamp on each attached display (gdi32)", 20 },
	.id = Backend.WIN32_RAMP,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// GDI is part of every Windows desktop: the probe only confirms that there is a backend to try.
fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.set(
		Cap.GAMMA_RAMP,
		{
			.reason = availability::Reason.DEGRADED,
			.note = "Windows may refuse a ramp silently (the read-back reports it); display changes reset the ramp",
		}
	);
	return alloc::new(allocator, WinRamp, { .allocator = allocator, .tick = options.tick });
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, (WinRamp*)state);
}

fn void run(void* state, ColorHub* hub, Host{Command}* host)
{
	WinRamp* ws = (WinRamp*)state;
	defer ws.free_displays();
	if (catch ws.open_displays()) return;
	Platform platform = { .context = ws, .write = &write_ramp, .release = &release_ramp };
	Engine engine;
	ws.start_engine(hub, &platform, &engine);
	defer engine.free();
	engine::serve_timed(&engine, host, ws.tick);
	ws.release_all(&engine);
}

<*
 Enumerate the attached displays and open a device context for each, reading each one's ramp
 before this service changes it. A display whose context cannot be opened is left out.

 @return? error::BACKEND_FAILURE : "EnumDisplayDevicesW found no display device list"
*>
fn void? WinRamp.open_displays(&self)
{
	List{windows_displays::DisplayDeviceW} attached;
	attached.init(tmem, 8);
	windows_displays::DisplayDeviceW device;
	device.cb = windows_displays::DISPLAY_DEVICE_SIZE;
	for (uint index = 0; windows_displays::enumDisplayDevicesW(null, index, &device, 0) != 0; index++)
	{
		if ((device.state_flags & windows_displays::ATTACHED_TO_DESKTOP) != 0) attached.push(device);
	}
	identity_words(self.identity[..])!;
	self.displays = alloc::new_array(self.allocator, WinDisplay, attached.len());
	usz count        = 0;
	ushort[8] driver = WIDE_DISPLAY;
	foreach (found : attached)
	{
		WinDisplay* slot = &self.displays[count];
		void* dc         = createDCW(driver[..].ptr, found.device_name[..].ptr, null, null);
		if (dc == null) continue;
		slot.dc = dc;
		slot.name = ascii(found.device_name[..], self.allocator);
		slot.has_original = getDeviceGammaRamp(dc, &slot.original) != 0;
		count++;
	}
	self.displays = self.displays[0:count];
}

// Free the displays: close their device contexts and their names.
fn void WinRamp.free_displays(&self)
{
	foreach (&slot : self.displays)
	{
		if (slot.dc != null) deleteDC(slot.dc);
		if (slot.name.len > 0) alloc::free(self.allocator, slot.name.ptr);
	}
	if (self.displays.len > 0) alloc::free(self.allocator, self.displays.ptr);
	self.displays = { };
}

<*
 The engine over the displays, with names and ramp size of each. The engine copies what it keeps.
 The outputs are built in temporary memory and released when this returns.
*>
fn void WinRamp.start_engine(&self, ColorHub* hub, Platform* platform, Engine* engine)
{
	@pool()
	{
		Output[] outputs = alloc::new_array(tmem, Output, self.displays.len);
		foreach (i, slot : self.displays)
		{
			outputs[i] = {
				.id = slot.name,
				.name = slot.name,
				.control = {
					.gamma_supported = true,
					.availability = availability::YES,
					.size = RAMP_SIZE,
					.brightness = (Level)1.0f,
				},
			};
		}
		engine.init(self.allocator, hub, platform, outputs);
	};
}

// Write `ramp` to display `index`, then read it back: SetDeviceGammaRamp may have refused it.
fn void? write_ramp(void* context, usz index, float[] ramp)
{
	WinRamp* ws      = (WinRamp*)context;
	WinDisplay* slot = &ws.displays[index];
	ramp::encode_u16(ramp, slot.words[..])!;
	if (setDeviceGammaRamp(slot.dc, &slot.words) == 0)
	{
		return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.WIN32,
			0,
			"SetDeviceGammaRamp failed on %s",
			slot.name
		)~;
	}
	ushort[RAMP_WORDS] readback;
	if (getDeviceGammaRamp(slot.dc, &readback) == 0 || !same_ramp(readback[..], slot.words[..]))
	{
		return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.WIN32,
			0,
			"%s: Windows did not apply the ramp",
			slot.name
		)~;
	}
}

// Engine callback: put display `index` back as it was: its own ramp, or the identity if it had none.
fn void release_ramp(void* context, usz index)
{
	WinRamp* ws      = (WinRamp*)context;
	WinDisplay* slot = &ws.displays[index];
	ushort* restore  = slot.has_original ? slot.original[..].ptr : ws.identity[..].ptr;
	if (setDeviceGammaRamp(slot.dc, restore) == 0)
	{
	}
}

// Restore every display the engine still has a ramp on.
fn void WinRamp.release_all(&self, Engine* engine)
{
	for (usz i = 0; i < self.displays.len; i++)
	{
		if (engine.displays[i].output.control.active) release_ramp(self, i);
	}
}

<*
 The ramp that maps every value to itself: entry i of each channel is i / 255 as a 16-bit word.

 @param out : "A ramp of RAMP_WORDS words"
*>
fn void? identity_words(ushort[] out)
{
	float[RAMP_WORDS] linear;
	ramp::fill(linear[..], RAMP_SIZE, kelvin::NEUTRAL, (Level)1.0f, 1.0)!;
	ramp::encode_u16(linear[..], out)!;
}

// Whether two ramps agree word by word within READBACK_TOLERANCE.
fn bool same_ramp(ushort[] a, ushort[] b)
{
	for (usz i = 0; i < a.len; i++)
	{
		if (math::abs((long)a[i] - (long)b[i]) > READBACK_TOLERANCE) return false;
	}
	return true;
}

// The display name as ASCII, copied into `allocator`. Device names are ASCII (`\\.\DISPLAY1`).
fn String ascii(ushort[] units, Allocator allocator)
{
	usz len = 0;
	while (len < units.len && units[len] != 0) len++;
	char[] text = alloc::new_array(allocator, char, (sz)len);
	for (usz i = 0; i < len; i++) text[i] = units[i] < 0x80 ? (char)units[i] : '?';
	return (String)text;
}