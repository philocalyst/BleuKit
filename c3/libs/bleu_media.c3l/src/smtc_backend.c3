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

<* Consecutive failed polls after which the failure is published (see `poll_counting`). *>
const usz POLL_FAILURE_LIMIT = 3;

<* What the backend remembers of one session between polls, keyed by its app user model id. *>
struct Known
{
	ulong handle;
	String id; // owned by the backend's allocator
	String title; // copies owned by the backend's allocator: a session whose read failed is reported from them
	String artist;
	String album;
	Playback status;
	Duration status_since;
	long position_ticks; // as last reported, to tell an unchanged reading
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
// Nothing touches COM here: `open` may run on any thread. The session manager is probed by the worker (see `run`).
fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	fill_capabilities(capabilities);
	return alloc::new(allocator, Backend, { .allocator = allocator, .refresh = options.refresh });
}

fn void fill_capabilities(Capabilities* capabilities) @private
{
	capabilities.init(availability::YES);
	capabilities.values[Cap.VOLUME.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"SMTC has no volume control"
	);
	capabilities.values[Cap.RAISE.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"SMTC has no raise"
	);
	capabilities.values[Cap.QUIT.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"SMTC has no quit"
	);
	capabilities.values[Cap.PUBLISH_SESSION.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"Publishing our session is not in v1"
	);
	capabilities.values[Cap.NOW_PLAYING_PRIVATE.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_OS,
		"SMTC is the Windows interface"
	);
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

// Activate the session manager (`RequestAsync`). The caller releases it.
fn smtc_api::Manager*? request_manager()
{
	com_ptr::Com{smtc_api::ManagerStatics} factory = winrt::activation_factory{smtc_api::ManagerStatics}(
		smtc_api::MANAGER_CLASS,
		smtc_api::IID_MANAGER_STATICS
	)!;
	defer factory.release();
	void* operation     = null;
	hresult::Hresult hr = factory.ptr.vtbl.request_async(factory.ptr, &operation);
	if (hr.failed()) return errors::raise_hresult(hr, "RequestAsync")~;
	void* manager = await_object(operation)!;
	return (smtc_api::Manager*)manager;
}

<*
 Wait for an `IAsyncOperation<T>` whose result is an object, and return that
 object (owned by the caller). The operation itself is released here.
*>
fn void*? await_object(void* operation)
{
	com_ptr::Com{com::IUnknown} owned = { .ptr = (com::IUnknown*)operation };
	defer owned.release();
	winrt::AsyncStatus status = winrt::wait_async(&owned, CALL_TIMEOUT)!;
	if (status != winrt::AsyncStatus.COMPLETED) return error::raise(
		error::BACKEND_FAILURE,
		error::Domain.INTERNAL,
		(int)status,
		"an SMTC call did not complete"
	)~;
	smtc_api::AsyncObject* done = (smtc_api::AsyncObject*)operation;
	void* result                = null;
	hresult::Hresult hr         = done.vtbl.get_results(done, &result);
	if (hr.failed()) return errors::raise_hresult(hr, "IAsyncOperation.GetResults")~;
	return result;
}

// As `await_object`, for an `IAsyncOperation<Boolean>`: the value the session returned.
fn bool? await_bool(void* operation)
{
	com_ptr::Com{com::IUnknown} owned = { .ptr = (com::IUnknown*)operation };
	defer owned.release();
	winrt::AsyncStatus status = winrt::wait_async(&owned, CALL_TIMEOUT)!;
	if (status != winrt::AsyncStatus.COMPLETED) return error::raise(
		error::BACKEND_FAILURE,
		error::Domain.INTERNAL,
		(int)status,
		"an SMTC call did not complete"
	)~;
	smtc_api::AsyncBool* done = (smtc_api::AsyncBool*)operation;
	bool result               = false;
	hresult::Hresult hr       = done.vtbl.get_results(done, &result);
	if (hr.failed()) return errors::raise_hresult(hr, "IAsyncOperation<Boolean>.GetResults")~;
	return result;
}

<* An HSTRING returned as an owned object, copied into `allocator`. A null handle is "". *>
fn String? hstring_of(void* handle, Allocator allocator)
{
	hstring::Hstring text = { .handle = handle };
	defer text.close();
	return text.to_string(allocator);
}


// One call that returns an object through an out pointer. The object is the caller's.
fn void*? object_of(GetObjectFn getter, void* self)
{
	void* out           = null;
	hresult::Hresult hr = getter(self, &out);
	if (hr.failed()) return errors::raise_hresult(hr, "IInspectable call")~;
	return out;
}

fn bool? flag_of(GetBoolFn getter, void* self)
{
	bool value          = false;
	hresult::Hresult hr = getter(self, &value);
	if (hr.failed()) return errors::raise_hresult(hr, "IInspectable flag")~;
	return value;
}

fn int? int_of(GetIntFn getter, void* self)
{
	int value           = 0;
	hresult::Hresult hr = getter(self, &value);
	if (hr.failed()) return errors::raise_hresult(hr, "IInspectable enumeration")~;
	return value;
}

fn long? ticks_of(GetTicksFn getter, void* self)
{
	long value          = 0;
	hresult::Hresult hr = getter(self, &value);
	if (hr.failed()) return errors::raise_hresult(hr, "IInspectable ticks")~;
	return value;
}

// A nullable `IReference<Boolean>` read: unknown when the reference is null.
fn Maybe{bool} maybe_flag(void* reference) @local
{
	if (reference == null) return { };
	smtc_api::ReferenceBool* box = (smtc_api::ReferenceBool*)reference;
	if (try value = flag_of(box.vtbl.value, box)) return maybe::value(value);
	return { };
}

// The state of one session, read through its interfaces. Strings go to `allocator`.
fn Entry? read_entry(smtc_api::Session* session, Allocator allocator) @local
{
	Entry e;
	e.id = hstring_of(object_of(session.vtbl.source_app_user_model_id, session)!, allocator)!;

	void* info_raw = object_of(session.vtbl.get_playback_info, session)!;
	defer smtc_api::release_object(info_raw);
	smtc_api::PlaybackInfo* info = (smtc_api::PlaybackInfo*)info_raw;
	e.status = smtc_convert::playback_of_status(int_of(info.vtbl.playback_status, info)!);

	void* controls_raw = object_of(info.vtbl.controls, info)!;
	defer smtc_api::release_object(controls_raw);
	smtc_api::PlaybackControls* controls = (smtc_api::PlaybackControls*)controls_raw;
	e.reported = {
		.play = flag_of(controls.vtbl.is_play_enabled, controls)!,
		.pause = flag_of(controls.vtbl.is_pause_enabled, controls)!,
		.stop = flag_of(controls.vtbl.is_stop_enabled, controls)!,
		.next = flag_of(controls.vtbl.is_next_enabled, controls)!,
		.previous = flag_of(controls.vtbl.is_previous_enabled, controls)!,
		.toggle = flag_of(controls.vtbl.is_play_pause_toggle_enabled, controls)!,
		.position = flag_of(controls.vtbl.is_playback_position_enabled, controls)!,
		.rate = flag_of(controls.vtbl.is_playback_rate_enabled, controls)!,
		.shuffle = flag_of(controls.vtbl.is_shuffle_enabled, controls)!,
		.repeat = flag_of(controls.vtbl.is_repeat_enabled, controls)!,
	};

	void* repeat_raw = object_of(info.vtbl.auto_repeat_mode, info)!;
	defer smtc_api::release_object(repeat_raw);
	if (repeat_raw != null)
	{
		smtc_api::ReferenceInt* box = (smtc_api::ReferenceInt*)repeat_raw;
		e.loop = maybe::value(smtc_convert::loop_of_repeat(int_of(box.vtbl.value, box)!));
	}

	void* shuffle_raw = object_of(info.vtbl.is_shuffle_active, info)!;
	defer smtc_api::release_object(shuffle_raw);
	e.shuffle = maybe_flag(shuffle_raw);

	e.rate = 1.0;
	void* rate_raw = object_of(info.vtbl.playback_rate, info)!;
	defer smtc_api::release_object(rate_raw);
	if (rate_raw != null)
	{
		smtc_api::ReferenceDouble* box = (smtc_api::ReferenceDouble*)rate_raw;
		double rate                    = 1.0;
		hresult::Hresult hr            = box.vtbl.value(box, &rate);
		if (hr.failed()) return errors::raise_hresult(hr, "PlaybackRate")~;
		e.rate = media::sane_rate(rate);
	}
	if (e.status == Playback.PLAYING && e.rate == 0.0) e.status = Playback.PAUSED;

	void* timeline_raw = object_of(session.vtbl.get_timeline_properties, session)!;
	defer smtc_api::release_object(timeline_raw);
	smtc_api::Timeline* timeline = (smtc_api::Timeline*)timeline_raw;
	e.position_ticks = ticks_of(timeline.vtbl.position, timeline)!;
	e.updated_ticks = ticks_of(timeline.vtbl.last_updated, timeline)!;
	e.has_position = true;
	long start = ticks_of(timeline.vtbl.start_time, timeline)!;
	long end   = ticks_of(timeline.vtbl.end_time, timeline)!;
	e.has_length = end > start;
	e.length_ticks = end - start;

	void* props_operation = object_of(session.vtbl.try_get_media_properties_async, session)!;
	void* props_raw       = await_object(props_operation)!;
	defer smtc_api::release_object(props_raw);
	smtc_api::MediaProperties* props = (smtc_api::MediaProperties*)props_raw;
	e.title = hstring_of(object_of(props.vtbl.title, props)!, allocator)!;
	e.artist = hstring_of(object_of(props.vtbl.artist, props)!, allocator)!;
	e.album = hstring_of(object_of(props.vtbl.album_title, props)!, allocator)!;
	return e;
}

// The backend's state between polls.
struct Smtc
{
	Allocator allocator;
	smtc_api::Manager* manager;
	List{Known} known;
	ulong next_handle;
}

<* Activate the session manager and prepare the state. *>
fn void? Smtc.open(&self, Allocator allocator)
{
	self.allocator = allocator;
	self.next_handle = 1;
	self.known.init(allocator);
	self.manager = request_manager()!;
}

<* Release the manager and the remembered sessions. *>
fn void Smtc.close(&self)
{
	smtc_api::release_object(self.manager);
	self.forget();
	self.known.free();
}

// The session's `Known` record, or null.
fn Known* Smtc.find_id(&self, String id)
{
	foreach (&k : self.known.array_view())
	{
		if (k.id == id) return k;
	}
	return null;
}

// The session with `handle`, or null.
fn Known* Smtc.find_handle(&self, ulong handle)
{
	foreach (&k : self.known.array_view())
	{
		if (k.handle == handle) return k;
	}
	return null;
}

<* The sessions the manager reports now, as an owned view that the caller releases. *>
fn smtc_api::VectorView*? Smtc.sessions(&self)
{
	void* view          = null;
	hresult::Hresult hr = self.manager.vtbl.get_sessions(self.manager, &view);
	if (hr.failed()) return errors::raise_hresult(hr, "GetSessions")~;
	return (smtc_api::VectorView*)view;
}

// Number of sessions in `views`.
fn uint? view_size(smtc_api::VectorView* views)
{
	uint count          = 0;
	hresult::Hresult hr = views.vtbl.size(views, &count);
	if (hr.failed()) return errors::raise_hresult(hr, "IVectorView.Size")~;
	return count;
}

// Session `index` of `views`, as an owned object.
fn void*? view_at(smtc_api::VectorView* views, uint index)
{
	void* item          = null;
	hresult::Hresult hr = views.vtbl.get_at(views, index, &item);
	if (hr.failed()) return errors::raise_hresult(hr, "IVectorView.GetAt")~;
	return item;
}

<* Read every session, sort them by id and drop a second session with an id already seen. *>
fn void? Smtc.read_all(&self, List{Entry}* out, List{String}* failed)
{
	smtc_api::VectorView* views = self.sessions()!;
	defer smtc_api::release_object(views);
	uint count = view_size(views)!;
	for (uint i = 0; i < count; i++)
	{
		void* raw                  = view_at(views, i)!;
		smtc_api::Session* session = (smtc_api::Session*)raw;
		if (try entry = read_entry(session, tmem))
		{
			out.push(entry);
		}
		else if (try id = session_id(session, tmem))
		{
			failed.push(id);
		}
		smtc_api::release_object(raw);
	}
}

// The app user model id of `session`, copied into `allocator`.
fn String? session_id(smtc_api::Session* session, Allocator allocator) @private
{
	return hstring_of(object_of(session.vtbl.source_app_user_model_id, session)!, allocator);
}

<*
 One poll: read the sessions, update the remembered ones, and publish the state
 if it changed. A failed poll keeps the last state.
*>
fn void? Smtc.poll(&self, MediaHub* hub)
{
	@pool()
	{
		List{Entry} read;
		read.init(tmem);
		List{String} failed;
		failed.init(tmem);
		self.read_all(&read, &failed)!;
		Entry[] sorted = read.array_view();
		sort_by_id(sorted);
		Entry[] unique            = unique_by_id(sorted);
		Duration now              = media::monotonic_now();
		Time wall                 = time::now();
		Snapshot{State}* snapshot = hub.begin();
		snapshot.value = self.adopt(unique, failed.array_view(), snapshot.allocator(), now, wall);
		ulong[] none = { };
		media::publish_built(hub, snapshot, none);
	};
}

// Insertion sort by id: a handful of sessions.
fn void sort_by_id(Entry[] entries) @private
{
	for (sz i = 1; i < entries.len; i++)
	{
		Entry key = entries[i];
		sz j      = i - 1;
		while (j >= 0 && entries[j].id.compare_to(key.id) > 0)
		{
			entries[j + 1] = entries[j];
			j--;
		}
		entries[j + 1] = key;
	}
}

// The sorted entries with every id after its first occurrence removed (the slice shares storage).
fn Entry[] unique_by_id(Entry[] sorted) @private
{
	sz kept = 0;
	for (sz i = 0; i < sorted.len; i++)
	{
		if (kept > 0 && sorted[kept - 1].id == sorted[i].id) continue;
		sorted[kept] = sorted[i];
		kept++;
	}
	return sorted[0:kept];
}

<*
 Make the remembered sessions match this poll: handles stay with their ids,
 anchors and status times are kept while the reported values are unchanged, and
 a session whose read failed this time keeps its last good values (`failed` lists
 those ids). The players are built into `allocator`.
*>
fn State Smtc.adopt(&self, Entry[] entries, String[] failed, Allocator allocator, Duration now, Time wall)
{
	List{Known} next;
	next.init(self.allocator);
	foreach (&e : entries)
	{
		Known* old = self.find_id(e.id);
		Known k = {
			.id = media::copy_text(e.id, self.allocator),
			.title = media::copy_text(e.title, self.allocator),
			.artist = media::copy_text(e.artist, self.allocator),
			.album = media::copy_text(e.album, self.allocator),
			.handle = old != null ? old.handle : self.take_handle(),
			.status = e.status,
			.status_since = old != null && old.status == e.status ? old.status_since : now,
			.position_ticks = e.position_ticks,
			.updated_ticks = e.updated_ticks,
			.controls = smtc_convert::controls_of(e.reported),
			.rate = e.rate,
			.shuffle = e.shuffle,
			.loop = e.loop,
			.has_length = e.has_length,
			.length = smtc_convert::micros_of_ticks(e.length_ticks),
		};
		bool same = old != null && old.position_ticks == e.position_ticks && old.updated_ticks == e.updated_ticks;
		if (same)
		{
			k.position = old.position;
		}
		else if (e.has_position)
		{
			Duration age  = smtc_convert::age_of(e.updated_ticks, wall);
			Anchor anchor = { .position = smtc_convert::micros_of_ticks(e.position_ticks), .taken_at = now - age };
			k.position = maybe::value(anchor);
		}
		next.push(k);
	}
	foreach (&old : self.known.array_view())
	{
		if (contains_id(entries, old.id) || !contains_text(failed, old.id)) continue;
		next.push({
			.id = media::copy_text(old.id, self.allocator),
			.title = media::copy_text(old.title, self.allocator),
			.artist = media::copy_text(old.artist, self.allocator),
			.album = media::copy_text(old.album, self.allocator),
			.handle = old.handle,
			.status = old.status,
			.status_since = old.status_since,
			.position_ticks = old.position_ticks,
			.updated_ticks = old.updated_ticks,
			.position = old.position,
			.controls = old.controls,
			.rate = old.rate,
			.shuffle = old.shuffle,
			.loop = old.loop,
			.has_length = old.has_length,
			.length = old.length,
		});
	}
	usz count = next.size;
	if (count == 0)
	{
		self.forget();
		self.known = next;
		return { };
	}
	Player[] players    = alloc::new_array(allocator, Player, (sz)count);
	Playback[] statuses = alloc::new_array(tmem, Playback, (sz)count);
	Duration[] since    = alloc::new_array(tmem, Duration, (sz)count);
	foreach (i, &k : next.array_view())
	{
		players[i] = player_of(k, allocator);
		statuses[i] = k.status;
		since[i] = k.status_since;
	}
	self.forget();
	self.known = next;
	sz active = media::select_active(statuses, since);
	players[active].is_active = true;
	return { .players = players };
}

// The player a remembered session describes, with its strings copied into `allocator`.
fn Player player_of(Known* k, Allocator allocator) @private
{
	return {
		.handle = k.handle,
		.id = media::copy_text(k.id, allocator),
		.identity = media::copy_text(k.id, allocator),
		.status = k.status,
		.track = {
			.title = media::copy_text(k.title, allocator),
			.artists = artists_of(k.artist, allocator),
			.album = media::copy_text(k.album, allocator),
			.length = k.has_length ? maybe::value(k.length) : { },
		},
		.position = k.position,
		.rate = k.rate,
		.shuffle = k.shuffle,
		.loop = k.loop,
		.controls = k.controls,
	};
}

fn bool contains_id(Entry[] entries, String id) @private
{
	foreach (&e : entries) if (e.id == id) return true;
	return false;
}

fn bool contains_text(String[] texts, String text) @private
{
	foreach (t : texts) if (t == text) return true;
	return false;
}

// The one artist as a list, or none when there is no artist text.
fn String[] artists_of(String artist, Allocator allocator) @private
{
	if (artist.len == 0) return { };
	String[] list = alloc::new_array(allocator, String, 1);
	list[0] = artist.copy(allocator);
	return list;
}

// A fresh handle. Handles start at 1; zero means no player.
fn ulong Smtc.take_handle(&self)
{
	ulong handle = self.next_handle;
	self.next_handle++;
	return handle;
}

// Free the strings of the remembered sessions (the list itself is replaced by the caller).
fn void Smtc.forget(&self)
{
	foreach (k : self.known.array_view()) free_strings(self.allocator, k);
	self.known.free();
	self.known.init(self.allocator);
}

// Free the strings a remembered session owns (the list itself is the caller's business).
fn void free_strings(Allocator allocator, Known k) @private
{
	String[4] owned = { k.id, k.title, k.artist, k.album };
	foreach (text : owned)
	{
		if (text.len > 0) alloc::free(allocator, text.ptr);
	}
}

<*
 Open the session with app user model id `id`. The caller releases it.

 @return? NOT_FOUND : "No session has this id any more"
*>
fn smtc_api::Session*? Smtc.open_session(&self, String id, Allocator allocator)
{
	smtc_api::VectorView* views = self.sessions()!;
	defer smtc_api::release_object(views);
	uint count = view_size(views)!;
	for (uint i = 0; i < count; i++)
	{
		void* raw                  = view_at(views, i)!;
		smtc_api::Session* session = (smtc_api::Session*)raw;
		if (try text = session_id(session, allocator))
		{
			if (text == id) return session;
		}
		smtc_api::release_object(raw);
	}
	return NOT_FOUND~;
}

<* Carry out `c` and complete its operation, if it has one. *>
fn void Smtc.execute(&self, Command* c)
{
	CommandOp* op = c.op;
	if (catch err = self.perform(c))
	{
		if (op != null)
		{
			op.fail(err);
			op.release();
		}
		return;
	}
	if (op != null)
	{
		op.succeed(true);
		op.release();
	}
}

// The media session call that answers with a Boolean operation: true when the session accepted it.
fn void? settle(GetObjectFn call, void* self) @private
{
	void* operation = object_of(call, self)!;
	if (!(await_bool(operation)!)) return error::BACKEND_FAILURE~;
}

fn void? settle_int(SetIntAsyncFn call, void* self, int value) @private
{
	void* operation     = null;
	hresult::Hresult hr = call(self, value, &operation);
	if (hr.failed()) return errors::raise_hresult(hr, "session call")~;
	if (!(await_bool(operation)!)) return error::BACKEND_FAILURE~;
}

fn void? settle_double(SetDoubleAsyncFn call, void* self, double value) @private
{
	void* operation     = null;
	hresult::Hresult hr = call(self, value, &operation);
	if (hr.failed()) return errors::raise_hresult(hr, "session call")~;
	if (!(await_bool(operation)!)) return error::BACKEND_FAILURE~;
}

fn void? settle_flag(SetBoolAsyncFn call, void* self, bool value) @private
{
	void* operation     = null;
	hresult::Hresult hr = call(self, value, &operation);
	if (hr.failed()) return errors::raise_hresult(hr, "session call")~;
	if (!(await_bool(operation)!)) return error::BACKEND_FAILURE~;
}

fn void? settle_ticks(SetTicksAsyncFn call, void* self, long value) @private
{
	void* operation     = null;
	hresult::Hresult hr = call(self, value, &operation);
	if (hr.failed()) return errors::raise_hresult(hr, "session call")~;
	if (!(await_bool(operation)!)) return error::BACKEND_FAILURE~;
}

// Dispatch on the command kind, against the session whose id the state remembers.
fn void? Smtc.perform(&self, Command* c)
{
	if (c.kind == CommandKind.REFRESH) return;
	Known* k = self.find_handle(c.player);
	if (k == null) return NOT_FOUND~;
	if (!k.controls.allows(c.kind)) return error::UNSUPPORTED~;
	@pool()
	{
		smtc_api::Session* s = self.open_session(k.id, tmem)!;
		defer smtc_api::release_object(s);
		switch (c.kind)
		{
			case CommandKind.PLAY: return settle(s.vtbl.try_play_async, s);
			case CommandKind.PAUSE: return settle(s.vtbl.try_pause_async, s);
			case CommandKind.PLAY_PAUSE: return settle(s.vtbl.try_toggle_play_pause_async, s);
			case CommandKind.STOP: return settle(s.vtbl.try_stop_async, s);
			case CommandKind.NEXT: return settle(s.vtbl.try_skip_next_async, s);
			case CommandKind.PREVIOUS: return settle(s.vtbl.try_skip_previous_async, s);
			case CommandKind.SEEK: return settle_ticks(s.vtbl.try_change_playback_position_async, s, smtc_convert::ticks_of_micros(target_of(k, c.amount)!));
			case CommandKind.SET_POSITION: return settle_ticks(s.vtbl.try_change_playback_position_async, s, smtc_convert::ticks_of_micros(c.amount));
			case CommandKind.SET_RATE: return settle_double(s.vtbl.try_change_playback_rate_async, s, (double)c.rate);
			case CommandKind.SET_SHUFFLE: return settle_flag(s.vtbl.try_change_shuffle_active_async, s, c.flag);
			case CommandKind.SET_LOOP: return settle_int(s.vtbl.try_change_auto_repeat_mode_async, s, smtc_convert::repeat_of_loop(c.loop));
			case CommandKind.SET_VOLUME:
			case CommandKind.RAISE:
			case CommandKind.QUIT: return error::UNSUPPORTED~;
			case CommandKind.REFRESH: return;
		}
	};
}

// Where a relative seek of `offset` from `k` lands: the position now, plus the offset. Without an anchor there is nothing to move from.
fn Duration? target_of(Known* k, Duration offset) @private
{
	if (!k.position.has_value) return error::UNAVAILABLE~;
	Maybe{Duration} length = k.has_length ? maybe::value(k.length) : { };
	Duration at            = media::position_at(k.position.value, k.status, k.rate, length, media::monotonic_now());
	return at + offset;
}

<* The worker's loop: wait for a command or the refresh interval; run the commands; poll. *>
fn void run(void* state, MediaHub* hub, Host{Command}* host)
{
	Backend* backend = (Backend*)state;
	if (try runtime = winrt::enter(com::Model.MULTI_THREADED))
	{
		defer runtime.leave();
		run_entered(backend, hub, host);
	}
	else
	{
		media::emit_failure(hub, "COM could not start on the SMTC thread");
	}
}

fn void run_entered(Backend* backend, MediaHub* hub, Host{Command}* host) @private
{
	Smtc smtc;
	if (catch err = smtc.open(backend.allocator))
	{
		media::emit_failure(hub, error::last().message());
		return;
	}
	defer smtc.close();
	Poller poller;
	if (catch err = poller.init(mem, host.wakeup(), 1))
	{
		media::emit_failure(hub, "the SMTC worker has no wake-up");
		return;
	}
	defer poller.free();
	Command[COMMAND_BATCH] commands;
	usz failures = poll_counting(&smtc, hub, 0);
	while (!host.stopping())
	{
		if (catch err = poller.wait(backend.refresh))
		{
			if (err != TIMEOUT) break;
		}
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++) smtc.execute(&commands[i]);
		failures = poll_counting(&smtc, hub, failures);
	}
}

// One poll. A failed poll keeps the last state; after POLL_FAILURE_LIMIT failures in a row the failure is published once. Returns the run of failures.
fn usz poll_counting(Smtc* smtc, MediaHub* hub, usz failures) @private
{
	if (catch err = smtc.poll(hub))
	{
		usz run = failures + 1;
		if (run == POLL_FAILURE_LIMIT) media::emit_failure(hub, error::last().message());
		return run;
	}
	return 0;
}
