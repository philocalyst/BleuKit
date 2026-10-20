<*
 The Windows panel: the display driver's brightness IOCTLs on `\\.\LCD`.

 `\\.\LCD` is the display device's DOS name; `IOCTL_VIDEO_QUERY_DISPLAY_BRIGHTNESS`
 and `IOCTL_VIDEO_SET_DISPLAY_BRIGHTNESS` take a `DISPLAY_BRIGHTNESS` of policy,
 AC and DC bytes. The IOCTL codes are CTL_CODE(FILE_DEVICE_VIDEO = 0x23,
 0x126 / 0x127, METHOD_BUFFERED, FILE_ANY_ACCESS).

 COMPILED ONLY. Nothing here has run on Windows. The AC byte is taken as a
 percentage, and `VIDEO_SUPPORTED_BRIGHTNESS` is not read, so the driver's own
 step list is not honoured. Both are UNVERIFIED in docs/research/display.md
 (sections 2.3 and 4.2, B27 and B28). Only one display device is opened: `\\.\LCD`.

 Sources: mingw-w64 `ntddvdeo.h` lines 185-191 (IOCTL numbers) and 477-481
 (`DISPLAY_BRIGHTNESS`), as cited in docs/research/display.md section 2.3.
*>
module bleu::brightness::windows_panel @feat(WIN32);
import bleu::error, bleu::unit;

const uint GENERIC_READ                         =  0x80000000;
const uint GENERIC_WRITE                        =  0x40000000;
const uint FILE_SHARE_READ                      =  0x1;
const uint FILE_SHARE_WRITE                     =  0x2;
const uint OPEN_EXISTING                        =  3;
const uint FILE_DEVICE_VIDEO                    =  0x23;
const uint FUNCTION_QUERY_DISPLAY_BRIGHTNESS    =  0x126;
const uint FUNCTION_SET_DISPLAY_BRIGHTNESS      =  0x127;
const uint METHOD_BUFFERED                      =  0;
const uint FILE_ANY_ACCESS                      =  0;
const uint IOCTL_VIDEO_QUERY_DISPLAY_BRIGHTNESS =  (FILE_DEVICE_VIDEO << 16) | (FUNCTION_QUERY_DISPLAY_BRIGHTNESS << 2);
const uint IOCTL_VIDEO_SET_DISPLAY_BRIGHTNESS   =  (FILE_DEVICE_VIDEO << 16) | (FUNCTION_SET_DISPLAY_BRIGHTNESS << 2);
const String PANEL_PATH                         =  "\\\\.\\LCD";
const long INVALID_HANDLE                       = -1;

// The percentage scale of the AC byte (UNVERIFIED, see the module comment).
const long PANEL_STEPS = 100;

<* The size of `DISPLAY_BRIGHTNESS`: three bytes, no padding. *>
const uint DISPLAY_BRIGHTNESS_BYTES = 3;

<* `DISPLAY_BRIGHTNESS` from ntddvdeo.h. *>
struct DisplayBrightness
{
	char policy;
	char ac;
	char dc;
}

extern fn void* createFileA(
	ZString name,
	uint access,
	uint share,
	void* security,
	uint disposition,
	uint flags,
	void* template
) @cname("CreateFileA");
extern fn int deviceIoControl(
	void* device,
	uint code,
	void* input,
	uint input_size,
	void* output,
	uint output_size,
	uint* returned,
	void* overlapped
) @cname("DeviceIoControl");
extern fn int closeHandle(void* handle) @cname("CloseHandle");

<* An open `\\.\LCD`. Owned by one caller; close it when done. *>
struct Panel
{
	void* handle;
}

<*
 Open the panel device.

 @return? error::UNAVAILABLE : "There is no LCD display device (no internal panel, or the driver does not expose one)"
*>
fn Panel? open_panel()
{
	void* handle = createFileA(
		PANEL_PATH.zstr_tcopy(),
		GENERIC_READ | GENERIC_WRITE,
		FILE_SHARE_READ | FILE_SHARE_WRITE,
		null,
		OPEN_EXISTING,
		0,
		null
	);
	if ((long)handle == INVALID_HANDLE || handle == null)
	{
		return error::raise(error::UNAVAILABLE, error::Domain.WIN32, 0, "cannot open %s", PANEL_PATH)~;
	}
	return { .handle = handle };
}

fn void Panel.close(&self)
{
	if (self.handle) (void)closeHandle(self.handle);
	self.handle = null;
}

<* Query the current brightness. The returned `DisplayBrightness` keeps the policy byte for the set. *>
fn DisplayBrightness? Panel.query(&self)
{
	DisplayBrightness value;
	uint returned = 0;
	if (!deviceIoControl(
		self.handle,
		IOCTL_VIDEO_QUERY_DISPLAY_BRIGHTNESS,
		null,
		0,
		&value,
		DISPLAY_BRIGHTNESS_BYTES,
		&returned,
		null
	))
	{
		return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.WIN32,
			0,
			"the panel did not answer the brightness query"
		)~;
	}
	return value;
}

<* The panel's level, from the AC byte. *>
fn Level? Panel.level(&self)
{
	DisplayBrightness value = self.query()!;
	return unit::from_raw((long)(char)value.ac, 0, PANEL_STEPS);
}

<*
 Set the panel to `level`, keeping the policy the driver reports, and return the
 raw value written.
*>
fn long? Panel.write(&self, Level level)
{
	DisplayBrightness value = self.query()!;
	long raw                = level.to_raw(0, PANEL_STEPS);
	value.ac = (char)raw;
	value.dc = (char)raw;
	uint returned = 0;
	if (!deviceIoControl(
		self.handle,
		IOCTL_VIDEO_SET_DISPLAY_BRIGHTNESS,
		&value,
		DISPLAY_BRIGHTNESS_BYTES,
		null,
		0,
		&returned,
		null
	))
	{
		return error::raise(error::BACKEND_FAILURE, error::Domain.WIN32, 0, "the panel refused the brightness set")~;
	}
	return raw;
}