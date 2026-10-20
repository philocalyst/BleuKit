<*
 DwmGetWindowAttribute, the one dwmapi.dll call the Windows backend makes: whether
 a window is cloaked. Value and signature: dwmapi.h, checked against windows-sys 0.59.0
 `Graphics/Dwm/mod.rs` (line 17) and winapi 0.3.9 `um/dwmapi.rs` (line 37); the
 cloaked attribute is 14 in both.
*>
module bleu::windows::win32_dwm @feat(WIN32) @link("dwmapi");

extern fn uint dwm_get_window_attribute(
	void* hwnd,
	uint attribute,
	void* value,
	uint size
) @cname("DwmGetWindowAttribute");