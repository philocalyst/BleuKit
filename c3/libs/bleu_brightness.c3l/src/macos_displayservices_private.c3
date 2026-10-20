<*
 PRIVATE API. DisplayServices.framework is not a public SDK framework: its
 brightness functions are resolved at run time with `bleu::dl`, so a missing
 framework or a renamed symbol makes the NATIVE mechanism unavailable and never
 stops the library from loading.

 Symbols and signatures, from the Lunar bridging header (Lunar/Lunar-Bridging-Header.h,
 lines 49-75, as recorded in docs/research/display.md section 2.2, (a)):
 int  DisplayServicesGetBrightness(CGDirectDisplayID, float *out);   // 0..1
 int  DisplayServicesSetBrightness(CGDirectDisplayID, float);        // 0..1
 bool DisplayServicesCanChangeBrightness(CGDirectDisplayID);
 A status of 0 is KERN_SUCCESS (Lunar AppleNativeControl.swift, testReadAndWrite,
 lines 95-109). The framework path is the one Lunar and nriley/brightness open.

 Observed on: NOT RUN. Compiled for macos-aarch64 and macos-x64 only. The
 private names may change in any macOS release; that is why every use is
 resolved here and checked by `open_native`.
*>
module bleu::brightness::displayservices @feat(DARWIN);
import bleu::dl, bleu::error;

const String FRAMEWORK = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices";

alias GetBrightnessFn = fn int(uint display, float* out);
alias SetBrightnessFn = fn int(uint display, float value);
alias CanChangeFn = fn bool(uint display);

<* The three resolved functions. Each is required: a missing one makes the whole table unavailable. *>
struct DisplayServices
{
	GetBrightnessFn get_brightness @tag("sym", "DisplayServicesGetBrightness");
	SetBrightnessFn set_brightness @tag("sym", "DisplayServicesSetBrightness");
	CanChangeFn can_change @tag("sym", "DisplayServicesCanChangeBrightness");
}

<* The framework and the functions bound from it. The library stays loaded for the life of the process. *>
struct Native
{
	dl::Library library;
	DisplayServices api;
}

<*
 Open DisplayServices and bind its functions.

 @return? error::UNSUPPORTED : "The framework or one of its functions is not present"
*>
fn void? open_native(Native* native)
{
	String[1] candidates = { FRAMEWORK };
	native.library = dl::open(candidates[..])!;
	dl::bind(&native.api, &native.library)!;
}