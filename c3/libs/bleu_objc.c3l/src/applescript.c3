<*
 Running AppleScript from a service, for the few operations that have no public
 API and are done through System Events (for example sleep, restart or shutdown).

 Use it only when no other route exists: scripts need the user's Automation
 consent (a TCC grant for the target application), which may be refused or
 never given. A refusal arrives as `PERMISSION_DENIED`, not as a hang.

 Sources: `NSAppleScript` `initWithSource:` and `executeAndReturnError:` and the
 error dictionary keys `NSAppleScriptErrorMessage` and `NSAppleScriptErrorNumber`
 are taken from objc2-foundation `src/generated/NSAppleScript.rs`. The AppleEvent
 refusal `errAEEventNotPermitted` (-1743) is from objc2-core-services
 `src/generated/AE/AppleEvents.rs`.
*>
module bleu::objc::applescript @feat(DARWIN) @link("Foundation.framework");
import std::os::darwin::objc, bleu::objc, bleu::objc::codes, bleu::objc::foundation, bleu::error;

<* Key of the error dictionary holding the human-readable message (`NSString`). *>
extern const ObjId NS_APPLE_SCRIPT_ERROR_MESSAGE @cname("NSAppleScriptErrorMessage");
<* Key of the error dictionary holding the AppleScript error number (`NSNumber`). *>
extern const ObjId NS_APPLE_SCRIPT_ERROR_NUMBER @cname("NSAppleScriptErrorNumber");

<*
 Compile and run `source` in-process and return its text result.

 A script that returns no text (for example one whose last value is a number
 or a record) returns an empty string. A script that fails returns the
 classified error, with the AppleScript message and error number in the detail.

 The result is allocated from `allocator`. This function opens no temporary-memory
 pool, so a caller may pass `tmem`; the result then lives until the caller's
 enclosing `@pool()` closes. The Objective-C autorelease pool is drained on return,
 after the result has been copied.

 Blocking: the call waits for the target application to answer, which can take
 seconds. Run it on a service worker, never on a callback or the main thread.

 @param source : "The AppleScript source text"
 @param allocator : "Receives the result text"
 @return? error::INVALID_ARGUMENT : "when the script cannot be compiled"
 @return? error::PERMISSION_DENIED : "when the Automation grant is refused"
 @return? error::BACKEND_FAILURE : "for any other script failure"
*>
fn String? run_script(String source, Allocator allocator)
{
	objc::@autorelease_pool()
	{
		objc::Obj source_text = foundation::from_string(source);
		defer source_text.close();
		ObjId initialized = objc::class_named("NSAppleScript").alloc()
			.send(ObjId, "initWithSource:", source_text.ptr);
		objc::Obj script = objc::adopt(initialized);
		defer script.close();
		if (script.is_nil()) return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.NS_ERROR,
			0,
			"NSAppleScript could not be created"
		)~;

		ObjId error_info = null;
		ObjId result     = script.ptr.send(ObjId, "executeAndReturnError:", &error_info);
		if (!result)
		{
			return script_failure(error_info)~;
		}
		return foundation::to_string(result.send(ObjId, "stringValue"), allocator) ?? "";
	};
}

<*
 Build the fault for a failed script from its error dictionary. The message is
 copied into the detail; the number is classified as an OSStatus.
*>
fn fault script_failure(ObjId error_info) @local
{
	// The message is copied into temporary memory, so the pool scopes it. The fault
	// returned is a value; error::raise copies the text into the thread's detail.
	@pool()
	{
		foundation::NSInteger number = 0;
		String message               = "no error details";
		if (error_info)
		{
			objc::Obj number_object = objc::borrow(foundation::dictionary_value(error_info, NS_APPLE_SCRIPT_ERROR_NUMBER));
			defer number_object.close();
			number = foundation::number_as_long(number_object);
			message = foundation::to_string(
				foundation::dictionary_value(error_info, NS_APPLE_SCRIPT_ERROR_MESSAGE),
				tmem
			) ?? message;
		}
		fault f = number == codes::OS_STATUS_AE_EVENT_NOT_PERMITTED ? error::PERMISSION_DENIED
			: error::BACKEND_FAILURE;
		return error::raise(f, error::Domain.NS_ERROR, (int)number, "AppleScript: %s", message);
	};
}