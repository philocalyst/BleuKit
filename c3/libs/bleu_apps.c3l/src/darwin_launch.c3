<*
 Launching a macOS bundle through NSWorkspace.

 `openApplicationAtURL:configuration:completionHandler:` (or
 `openURLs:withApplicationAtURL:configuration:completionHandler:` when files or
 URIs are given) reports its result on a thread NSWorkspace chooses, so the
 worker waits for the completion handler with a deadline. That wait needs the
 handler to run on another thread; if the process never delivers it (no run
 loop on the main thread, for example) the launch times out with `TIMEOUT`.

 Sources: the Objective-C messages are the ones in the AppKit header
 `NSWorkspace.h` (`openApplicationAtURL:configuration:completionHandler:`,
 `openURLs:withApplicationAtURL:configuration:completionHandler:`,
 `sharedWorkspace`), bound through `bleu::objc`.
*>
module bleu::apps::app_bundles @feat(DARWIN);
import std::thread, std::time, std::os::darwin::objc, bleu::apps, bleu::deadline, bleu::error, bleu::objc, bleu::objc::foundation, bleu::rt::worker;

const Duration LAUNCH_WAIT = (Duration)10_000_000; // 10 s for the completion handler

<*
 The worker's side of one launch: the completion handler fills it in on a foreign
 thread. Heap-allocated, because a handler that arrives after a timeout still
 writes into it.
*>
struct LaunchWait
{
	Mutex mutex;
	ConditionVariable done;
	bool finished;
	long pid;
	bool failed;
	fault failure;
}

<* The completion handler: record the running app's pid, or the NSError. *>
fn void on_completion(void* user, ObjId app, ObjId error) @private
{
	LaunchWait* wait = (LaunchWait*)user;
	objc::@objc_entry()
	{
		wait.mutex.lock()!!;
		wait.finished = true;
		if (error)
		{
			wait.failed = true;
			wait.failure = foundation::raise_ns_error(error, "openApplicationAtURL");
		}
		else if (app)
		{
			wait.pid = (long)app.send(int, "processIdentifier");
		}
		wait.done.broadcast()!!;
		wait.mutex.unlock();
	};
}

<*
 Open the bundle, with the arguments and documents of `request`.

 @return? error::UNSUPPORTED : "A secondary action is requested; macOS apps have none"
 @return? TIMEOUT : "NSWorkspace did not report the launch in time"
 @return? error::BACKEND_FAILURE : "NSWorkspace reported an error (see the message)"
*>
fn Launched? launch_bundle(App* app, AppAction* action, LaunchRequest* request)
{
	if (action != null) return error::raise(
		error::UNSUPPORTED,
		error::Domain.INTERNAL,
		0,
		"%s has no actions",
		app.id
	)~;
	LaunchWait* wait = alloc::new(mem, LaunchWait);
	wait.mutex.init()!!;
	wait.done.init()!!;
	Block completion = objc::id_error_block(&on_completion, wait);
	defer completion.release();
	ObjId workspace     = objc::class_named("NSWorkspace").send(ObjId, "sharedWorkspace");
	ObjId configuration = objc::class_named("NSWorkspaceOpenConfiguration").send(ObjId, "configuration");
	ObjId arguments     = objc::class_named("NSMutableArray").send(ObjId, "array");
	foreach (argument : request.args)
	{
		objc::Obj text = foundation::from_string(argument);
		defer text.close();
		arguments.send_void("addObject:", text.ptr);
	}
	configuration.send_void("setArguments:", arguments);
	ObjId documents = objc::class_named("NSMutableArray").send(ObjId, "array");
	foreach (file : request.files) add_url(documents, file, true);
	foreach (uri : request.uris) add_url(documents, uri, false);
	ObjId bundle_url = bundle_file_url(app.target);
	if (documents_count(documents) == 0)
	{
		workspace.send_void(
			"openApplicationAtURL:configuration:completionHandler:",
			bundle_url,
			configuration,
			completion.id()
		);
	}
	else
	{
		workspace.send_void(
			"openURLs:withApplicationAtURL:configuration:completionHandler:",
			documents,
			bundle_url,
			configuration,
			completion.id()
		);
	}
	return await_launch(wait);
}

// The file URL of an absolute path.
fn ObjId bundle_file_url(String path) @local
{
	objc::Obj text = foundation::from_string(path);
	defer text.close();
	return objc::class_named("NSURL").send(ObjId, "fileURLWithPath:", text.ptr);
}

// Append the URL of a file path or of a URI to `documents`.
fn void add_url(ObjId documents, String text, bool is_file) @local
{
	objc::Obj ns_text = foundation::from_string(text);
	defer ns_text.close();
	ObjId url = is_file ? objc::class_named("NSURL")
		.send(ObjId, "fileURLWithPath:", ns_text.ptr) : objc::class_named("NSURL")
			.send(ObjId, "URLWithString:", ns_text.ptr);
	if (url) documents.send_void("addObject:", url);
}

fn usz documents_count(ObjId documents) @local => foundation::array_count(documents);

<*
 Wait for the completion handler, then take its result. A timed-out wait leaves
 the record to the handler, which may still arrive.
*>
fn Launched? await_launch(LaunchWait* wait) @local
{
	wait.mutex.lock()!!;
	Deadline deadline = deadline::after(LAUNCH_WAIT);
	while (!wait.finished)
	{
		if (!deadline.wait(&wait.done, &wait.mutex))
		{
			wait.mutex.unlock();
			return TIMEOUT~;
		}
	}
	bool failed   = wait.failed;
	fault failure = wait.failure;
	long pid      = wait.pid;
	wait.mutex.unlock();
	wait.mutex.destroy();
	wait.done.destroy()!!;
	alloc::free(mem, wait);
	if (failed) return failure~;
	return { .route = BUNDLE_OPEN, .pid = pid };
}