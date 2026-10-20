<*
 The battery service in C: options, an opaque handle, state snapshots, waiting,
 listeners, event readers and the JSON form. Other services copy this file and
 change the names; `docs/CAPI.md` lists the steps.
*>
module bleu::capi::battery_api;
import std::thread, std::time, bleu::battery, bleu::error, bleu::json, bleu::observe, bleu::stream, bleu::capi, bleu::rt::foreign;

<*
 Options for `bleu_battery_open`. Zero every member you do not set: zero means
 the default. `struct_size` must be sizeof the struct the caller compiled against.
*>
struct BatteryOptions @export("bleu_battery_options_t")
{
	uint struct_size;
	battery::Backend backend;
	ulong poll_ms;
	ZString root;
}

<*
 A battery service. Opaque: use the functions. Callable from any thread. A
 listener of the same handle must not call into it; such a call returns INVALID_STATE.
*>
// capi:opaque
struct BatteryHandle @export("bleu_battery_t")
{
	battery::Battery* service;
	Mutex mutex;
	BatteryWatch* watches;
	ulong next_watch_id;
	uint readers;
	String backend_name;
}

<*
 A listener registered with `bleu_battery_watch`. It runs on the service's worker
 thread, and once on the calling thread for the current state at registration. It
 must return quickly, must not block, and must not call back into this service.
 The snapshot is a view valid only during the call; `bleu_snapshot_retain` keeps it.
*>
alias BatteryListener = fn void(void* context, capi::CSnapshot* snapshot);

// One registered listener. Freed by `bleu_battery_unwatch` or `bleu_battery_close`.
struct BatteryWatch
{
	BatteryHandle* owner;
	ulong id;
	BatteryListener callback;
	void* context;
	observe::WatchId{battery::State} native;
	BatteryWatch* next;
}

const capi::SnapshotOps BATTERY_SNAPSHOT = {
	.service = capi::Service.BATTERY,
	.retain = &battery_snapshot_retain,
	.release = &battery_snapshot_release,
	.generation = &battery_snapshot_generation,
	.json = &battery_snapshot_json,
};

const capi::PacketOps BATTERY_PACKET = {
	.service = capi::Service.BATTERY,
	.release = &battery_packet_release,
};

const capi::ReaderOps BATTERY_READER = {
	.service = capi::Service.BATTERY,
	.next = &battery_reader_next,
	.take_dropped = &battery_reader_take_dropped,
	.release = &battery_reader_release,
	.packets = &BATTERY_PACKET,
};

fn void battery_snapshot_retain(void* native)
{
	Snapshot{battery::State}* snapshot = (Snapshot{battery::State}*)native;
	snapshot.retain();
}

fn void battery_snapshot_release(void* native)
{
	Snapshot{battery::State}* snapshot = (Snapshot{battery::State}*)native;
	snapshot.release();
}

fn ulong battery_snapshot_generation(void* native)
{
	Snapshot{battery::State}* snapshot = (Snapshot{battery::State}*)native;
	return snapshot.generation;
}

fn String? battery_snapshot_json(void* native, Allocator allocator)
{
	Snapshot{battery::State}* snapshot = (Snapshot{battery::State}*)native;
	return json::to_json(allocator, snapshot.value);
}

fn void*? battery_reader_next(void* native, Duration timeout)
{
	stream::Reader{battery::Event}* reader = (stream::Reader{battery::Event}*)native;
	Snapshot{battery::Event}* packet = reader.next(timeout)!;
	return (void*)packet;
}

fn ulong battery_reader_take_dropped(void* native)
{
	stream::Reader{battery::Event}* reader = (stream::Reader{battery::Event}*)native;
	return reader.take_dropped();
}

fn void battery_reader_release(void* native)
{
	stream::Reader{battery::Event}* reader = (stream::Reader{battery::Event}*)native;
	reader.release();
}

fn void battery_packet_release(void* native)
{
	Snapshot{battery::Event}* packet = (Snapshot{battery::Event}*)native;
	packet.release();
}

// A reader on this handle is gone: the handle may close again once none are left.
fn void battery_reader_done(void* owner)
{
	BatteryHandle* handle = (BatteryHandle*)owner;
	handle.mutex.lock()!!;
	handle.readers--;
	handle.mutex.unlock();
}

// The listener the observable calls: it wraps the snapshot as a view and enters the callback mark.
fn void battery_listener(void* context, Snapshot{battery::State}* snapshot)
{
	BatteryWatch* watch = (BatteryWatch*)context;
	capi::CSnapshot view = capi::view_of(&BATTERY_SNAPSHOT, snapshot);
	void* previous = capi::enter_callback(watch.owner);
	defer capi::leave_callback(previous);
	watch.callback(watch.context, &view);
}

// Unlink and return the watch with `id`, or null.
fn BatteryWatch* remove_watch(BatteryWatch** head, ulong id)
{
	BatteryWatch** link = head;
	while (*link)
	{
		BatteryWatch* watch = *link;
		if (watch.id == id)
		{
			*link = watch.next;
			return watch;
		}
		link = &watch.next;
	}
	return null;
}

fn void free_watches(BatteryWatch* watch)
{
	while (watch)
	{
		BatteryWatch* next = watch.next;
		alloc::free(mem, watch);
		watch = next;
	}
}

<*
 Open a battery service. Pass NULL for the defaults. The handle is released with
 `bleu_battery_close`.
*>
fn capi::CStatus bleu_battery_open(BatteryOptions* options, BatteryHandle** out) @export("bleu_battery_open")
{
	capi::@capi_entry()
	{
		if (!out) return capi::argument_error("out must not be NULL");
		*out = null;
		BatteryOptions given = { };
		if (options)
		{
			capi::CStatus status = capi::take_options(&given, BatteryOptions::size, options, options.struct_size);
			if (status != capi::CStatus.OK) return status;
		}
		if (given.poll_ms > capi::MAX_MILLISECONDS) return capi::argument_error("poll_ms is longer than one year");
		battery::Options native = {
			.backend = given.backend,
			.poll = (Duration)(given.poll_ms * 1000),
			.root = capi::text_of(given.root),
		};
		battery::Battery*? opened = battery::open(mem, native);
		if (catch err = opened) return capi::report(err, "the battery service could not be opened");
		BatteryHandle* handle = alloc::new(mem, BatteryHandle);
		*handle = { .service = opened, .backend_name = opened.backend_name().copy(mem) };
		handle.mutex.init()!!;
		*out = handle;
		return capi::CStatus.OK;
	};
}

<*
 Stop the service and free the handle. Fails with INVALID_STATE, and leaves the
 handle usable, while readers obtained from it are not yet released. Listeners
 are removed. Do not call it while another thread is inside a call on the handle.
*>
fn capi::CStatus bleu_battery_close(BatteryHandle* handle) @export("bleu_battery_close")
{
	capi::@capi_entry()
	{
		if (!handle) return capi::argument_error("handle must not be NULL");
		if (capi::is_inside_callback(handle)) return capi::reentry_refused();
		handle.mutex.lock()!!;
		if (handle.readers > 0)
		{
			handle.mutex.unlock();
			return capi::report(error::INVALID_STATE, "readers from this service are still open");
		}
		BatteryWatch* watches = handle.watches;
		handle.watches = null;
		handle.mutex.unlock();
		handle.service.close();
		free_watches(watches);
		handle.mutex.destroy();
		alloc::free(mem, handle);
		return capi::CStatus.OK;
	};
}

<* The name of the backend in use ("sysfs", "upower", "iokit", "win32"). Free it with `bleu_free`. *>
fn capi::CStatus bleu_battery_backend_name(BatteryHandle* handle, char** out, usz* len) @export("bleu_battery_backend_name")
{
	capi::@capi_entry()
	{
		if (!handle || !out || !len) return capi::argument_error("handle, out and len must not be NULL");
		return capi::copy_out(handle.backend_name, out, len);
	};
}

<* Whether a capability works with this backend, and if not, why. *>
fn capi::CStatus bleu_battery_capability(BatteryHandle* handle, battery::Cap cap, capi::Capability* out) @export("bleu_battery_capability")
{
	capi::@capi_entry()
	{
		if (!handle || !out) return capi::argument_error("handle and out must not be NULL");
		if ((usz)cap.ordinal > (usz)battery::Cap.PERIPHERALS.ordinal) return capi::argument_error("unknown capability");
		capi::fill_capability(out, handle.service.capability(cap));
		return capi::CStatus.OK;
	};
}

<* Ask the backend to re-read the hardware now. *>
fn capi::CStatus bleu_battery_refresh(BatteryHandle* handle) @export("bleu_battery_refresh")
{
	capi::@capi_entry()
	{
		if (!handle) return capi::argument_error("handle must not be NULL");
		if (capi::is_inside_callback(handle)) return capi::reentry_refused();
		if (catch err = handle.service.refresh()) return capi::report(err, "the refresh request was not queued");
		return capi::CStatus.OK;
	};
}

<* The newest state, as an owned snapshot to release with `bleu_snapshot_release`. *>
fn capi::CStatus bleu_battery_snapshot(BatteryHandle* handle, capi::CSnapshot** out) @export("bleu_battery_snapshot")
{
	capi::@capi_entry()
	{
		if (!handle || !out) return capi::argument_error("handle and out must not be NULL");
		if (capi::is_inside_callback(handle)) return capi::reentry_refused();
		*out = null;
		Snapshot{battery::State}*? latest = handle.service.latest();
		if (catch err = latest) return capi::report(err, "the battery state has not been read yet");
		*out = capi::new_snapshot(&BATTERY_SNAPSHOT, latest, true);
		return capi::CStatus.OK;
	};
}

<*
 The newest state as JSON, without any binding: the same text `bleu_snapshot_json`
 gives for a snapshot. Free the buffer with `bleu_free`.
*>
fn capi::CStatus bleu_battery_snapshot_json(BatteryHandle* handle, char** out, usz* len) @export("bleu_battery_snapshot_json")
{
	capi::@capi_entry()
	{
		if (!handle || !out || !len) return capi::argument_error("handle, out and len must not be NULL");
		if (capi::is_inside_callback(handle)) return capi::reentry_refused();
		Snapshot{battery::State}*? latest = handle.service.latest();
		if (catch err = latest) return capi::report(err, "the battery state has not been read yet");
		defer latest.release();
		String text = json::to_json(tmem, latest.value)!!;
		return capi::copy_out(text, out, len);
	};
}

<*
 Block until a state newer than `seen` exists, then return it as an owned snapshot.
 Start with `seen` 0 and pass the previous snapshot's generation after that.
 `timeout_ms` is -1 to wait forever, 0 to only poll.
*>
fn capi::CStatus bleu_battery_wait(BatteryHandle* handle, ulong seen, long timeout_ms, capi::CSnapshot** out) @export("bleu_battery_wait")
{
	capi::@capi_entry()
	{
		if (!handle || !out) return capi::argument_error("handle and out must not be NULL");
		if (timeout_ms < -1) return capi::argument_error("timeout_ms must be -1 or more");
		if (capi::is_inside_callback(handle)) return capi::reentry_refused();
		*out = null;
		Snapshot{battery::State}*? next = handle.service.wait_after(seen, capi::wait_duration(timeout_ms));
		if (catch err = next) return capi::report(err, "no newer battery state arrived");
		*out = capi::new_snapshot(&BATTERY_SNAPSHOT, next, true);
		return capi::CStatus.OK;
	};
}

<*
 The snapshot a `bleu_battery_snapshot_state` pointer belongs to: the state is
 borrowed and valid until that snapshot is released. Returns NULL for a handle
 of another service.
*>
fn battery::State* bleu_battery_snapshot_state(capi::CSnapshot* snapshot) @export("bleu_battery_snapshot_state")
{
	foreign::@foreign_entry()
	{
		if (!snapshot || snapshot.service != capi::Service.BATTERY) return null;
		Snapshot{battery::State}* state = (Snapshot{battery::State}*)snapshot.native;
		return &state.value;
	};
}

<*
 Register a listener; `out_id` receives the id for `bleu_battery_unwatch`. The
 listener runs on the worker thread for every later state, and once immediately
 on this thread for the current one.
*>
fn capi::CStatus bleu_battery_watch(BatteryHandle* handle, BatteryListener callback, void* context, ulong* out_id) @export("bleu_battery_watch")
{
	capi::@capi_entry()
	{
		if (!handle || !callback || !out_id) return capi::argument_error("handle, callback and out_id must not be NULL");
		if (capi::is_inside_callback(handle)) return capi::reentry_refused();
		BatteryWatch* watch = alloc::new(mem, BatteryWatch);
		*watch = { .owner = handle, .callback = callback, .context = context };
		handle.mutex.lock()!!;
		watch.id = ++handle.next_watch_id;
		handle.mutex.unlock();
		watch.native = handle.service.watch(&battery_listener, watch);
		handle.mutex.lock()!!;
		watch.next = handle.watches;
		handle.watches = watch;
		handle.mutex.unlock();
		*out_id = watch.id;
		return capi::CStatus.OK;
	};
}

<* Remove a listener. When this returns, the listener is not running and will not run again. *>
fn capi::CStatus bleu_battery_unwatch(BatteryHandle* handle, ulong id) @export("bleu_battery_unwatch")
{
	capi::@capi_entry()
	{
		if (!handle) return capi::argument_error("handle must not be NULL");
		if (capi::is_inside_callback(handle)) return capi::reentry_refused();
		handle.mutex.lock()!!;
		BatteryWatch* found = remove_watch(&handle.watches, id);
		handle.mutex.unlock();
		if (!found) return capi::report(NOT_FOUND, "no listener has this id");
		handle.service.unwatch(found.native);
		alloc::free(mem, found);
		return capi::CStatus.OK;
	};
}

<*
 Subscribe to battery events (sources added or removed, mains changed). Read them
 with `bleu_reader_next`; release the reader before closing the handle.
*>
fn capi::CStatus bleu_battery_subscribe(BatteryHandle* handle, capi::CReader** out) @export("bleu_battery_subscribe")
{
	capi::@capi_entry()
	{
		if (!handle || !out) return capi::argument_error("handle and out must not be NULL");
		if (capi::is_inside_callback(handle)) return capi::reentry_refused();
		*out = null;
		stream::Reader{battery::Event}*? reader = handle.service.subscribe();
		if (catch err = reader) return capi::report(err, "the battery service is closed");
		handle.mutex.lock()!!;
		handle.readers++;
		handle.mutex.unlock();
		capi::CReader* result = alloc::new(mem, capi::CReader);
		*result = { .ops = &BATTERY_READER, .native = reader, .owner = handle, .owner_release = &battery_reader_done };
		*out = result;
		return capi::CStatus.OK;
	};
}

<* The event carried by a packet from `bleu_battery_subscribe`. Borrowed until the packet is released. *>
fn battery::Event* bleu_battery_packet_event(capi::CPacket* packet) @export("bleu_battery_packet_event")
{
	foreign::@foreign_entry()
	{
		if (!packet || packet.ops.service != capi::Service.BATTERY) return null;
		Snapshot{battery::Event}* event = (Snapshot{battery::Event}*)packet.native;
		return &event.value;
	};
}
