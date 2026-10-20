<*
 The Windows backend: System Media Transport Controls (SMTC) sessions.

 Polling, not events. The session manager's change events need COM delegate
 objects implemented in this library; they are not in v1. Instead the worker
 reads every session once per refresh interval (one second by default) and
 after each command, and publishes the state when it changed. Seeks reported by
 SMTC are visible as position changes, not as `SEEKED` events.

 Each session's position is anchored as SMTC reports it: `Position` as of
 `LastUpdatedTime`. The anchor's monotonic time is the reading time minus the
 age of that timestamp, so the position extrapolates correctly (see `position.c3`).
 The anchor is kept while the reported pair is unchanged, so a state that did
 not change stays equal and publishes nothing.

 Not done: volume, raise and quit (SMTC has no such calls); track ids (SMTC
 has none, so `SetPosition` cannot be checked for a stale track); thumbnails.
 Not run anywhere: type-checked for the Windows targets only.
*>
module bleu::media::smtc @feat(WIN32);
import std::collections::list, std::collections::maybe, std::time, bleu::availability, bleu::error, bleu::media, bleu::media::smtc_api, bleu::media::smtc_convert, bleu::observe, bleu::operation, bleu::rt::poller, bleu::rt::worker, bleu::service, bleu::unit, bleu::win::com, bleu::win::com_ptr, bleu::win::errors, bleu::win::hresult, bleu::win::hstring, bleu::win::winrt;

<* How long one asynchronous session call may take before it counts as failed. *>
const Duration CALL_TIMEOUT = (Duration)5_000_000;

<* Commands taken from the mailbox per pass of the loop. *>
const usz COMMAND_BATCH = 16;

<* What the backend remembers of one session between polls, keyed by its app user model id. *>
struct Known
{
	ulong handle;
	String id;                 // owned by the backend's allocator
	Playback status;
	Duration status_since;
	long position_ticks;       // as last reported, to tell an unchanged reading
	long updated_ticks;
	Maybe{Anchor} position;
	Controls controls;
	PlaybackRate rate;
	Maybe{bool} shuffle;
	Maybe{Loop} loop;
	bool has_length;
	Duration length;
}

<* One session as read this poll. Its strings live in the poll's temporary memory. *>
struct Entry
{
	String id;
	String title;
	String artist;
	String album;
	Playback status;
	ReportedControls reported;
	Maybe{bool} shuffle;
	Maybe{Loop} loop;
	PlaybackRate rate;
	bool has_position;
	long position_ticks;
	long updated_ticks;
	bool has_length;
	long length_ticks;
}

struct Backend
{
	Allocator allocator;
	Duration refresh;
}

const Driver DRIVER = {
	.info = { "smtc", "Windows System Media Transport Controls sessions", 10 },
	.id = media::Backend.SMTC,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// Cheap: the session manager is asked for in `create`.
fn bool probe(Options* options) => true;

<* Activate the session manager once on this thread, so `open` fails when SMTC is absent. *>
fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	fill_capabilities(capabilities);
	winrt::Runtime runtime = winrt::enter(com::Model.MULTI_THREADED)!;
	defer runtime.leave();
	smtc_api::Manager* manager = request_manager()!;
	release_object(manager);
	return alloc::new(allocator, Backend, { .allocator = allocator, .refresh = options.refresh });
}

fn void fill_capabilities(Capabilities* capabilities) @private
{
	capabilities.init(availability::YES);
	capabilities.values[Cap.VOLUME.ordinal] = availability::no(availability::Reason.UNSUPPORTED_BACKEND, "SMTC has no volume control");
	capabilities.values[Cap.RAISE.ordinal] = availability::no(availability::Reason.UNSUPPORTED_BACKEND, "SMTC has no raise");
	capabilities.values[Cap.QUIT.ordinal] = availability::no(availability::Reason.UNSUPPORTED_BACKEND, "SMTC has no quit");
	capabilities.values[Cap.PUBLISH_SESSION.ordinal] = availability::no(availability::Reason.UNSUPPORTED_BACKEND, "Publishing our session is not in v1");
	capabilities.values[Cap.NOW_PLAYING_PRIVATE.ordinal] = availability::no(availability::Reason.UNSUPPORTED_OS, "SMTC is the Windows interface");
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

// Activate the session manager (`RequestAsync`). The caller releases it.
fn smtc_api::Manager*? request_manager() @local
{
	com_ptr::Com{smtc_api::ManagerStatics} factory = winrt::activation_factory{smtc_api::ManagerStatics}(smtc_api::MANAGER_CLASS, smtc_api::IID_MANAGER_STATICS)!;
	defer factory.release();
	void* operation = null;
	hresult::Hresult hr = factory.ptr.vtbl.request_async(factory.ptr, &operation);
	if (hr.failed()) return errors::raise_hresult(hr, "RequestAsync")~;
	void* manager = await_object(operation)!;
	return (smtc_api::Manager*)manager;
}

<*
 Wait for an `IAsyncOperation<T>` whose result is an object, and return that
 object (owned by the caller). The operation itself is released here.
*>
fn void*? await_object(void* operation) @local
{
	com_ptr::Com{com::IUnknown} owned = { .ptr = (com::IUnknown*)operation };
	defer owned.release();
	winrt::AsyncStatus status = winrt::wait_async(&owned, CALL_TIMEOUT)!;
	if (status != winrt::AsyncStatus.COMPLETED) return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, (int)status, "an SMTC call did not complete")~;
	smtc_api::AsyncObject* done = (smtc_api::AsyncObject*)operation;
	void* result = null;
	hresult::Hresult hr = done.vtbl.get_results(done, &result);
	if (hr.failed()) return errors::raise_hresult(hr, "IAsyncOperation.GetResults")~;
	return result;
}

// As `await_object`, for an `IAsyncOperation<Boolean>`: the value the session returned.
fn bool? await_bool(void* operation) @local
{
	com_ptr::Com{com::IUnknown} owned = { .ptr = (com::IUnknown*)operation };
	defer owned.release();
	winrt::AsyncStatus status = winrt::wait_async(&owned, CALL_TIMEOUT)!;
	if (status != winrt::AsyncStatus.COMPLETED) return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, (int)status, "an SMTC call did not complete")~;
	smtc_api::AsyncBool* done = (smtc_api::AsyncBool*)operation;
	bool result = false;
	hresult::Hresult hr = done.vtbl.get_results(done, &result);
	if (hr.failed()) return errors::raise_hresult(hr, "IAsyncOperation<Boolean>.GetResults")~;
	return result;
}

<* An HSTRING returned as an owned object, copied into `allocator`. A null handle is "". *>
fn String? hstring_of(void* handle, Allocator allocator) @local
{
	hstring::Hstring text = { .handle = handle };
	defer text.close();
	return text.to_string(allocator);
}

// The sessions as the manager reports them now. The caller releases the view.
fn smtc_api::VectorView*? Backend.sessions(&self, smtc_api::Manager* manager) @local
{
	void* view = null;
	hresult::Hresult hr = manager.vtbl.get_sessions(manager, &view);
	if (hr.failed()) return errors::raise_hresult(hr, "GetSessions")~;
	return (smtc_api::VectorView*)view;
}
