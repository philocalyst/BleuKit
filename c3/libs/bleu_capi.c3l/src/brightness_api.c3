<*
 The brightness service in C: options, an opaque handle, state snapshots, waiting,
 listeners, event readers, set-level operations and the JSON form. It follows
 `battery_api.c3` line for line where the two services are alike.
*>
module bleu::capi::brightness_api;
import std::thread, std::time, bleu::brightness, bleu::error, bleu::json, bleu::observe, bleu::operation, bleu::stream, bleu::unit, bleu::capi, bleu::rt::foreign;

<*
 Options for `bleu_brightness_open`. Zero every member you do not set. `bus_address`
 is the D-Bus address that carries logind on Linux; NULL or an empty string means the
 system bus.
*>
struct BrightnessOptions @export("bleu_brightness_options_t")
{
	uint struct_size;
	brightness::Backend backend;
	ulong poll_ms;
	ulong transition_step_ms;
	ZString root;
	ZString bus_address;
}

<*
 A request to set one device's light. `device` is an id from the state, `level` is
 clamped to 0.0 .. 1.0, and `transition_ms` 0 changes it at once.
*>
struct BrightnessSetRequest @export("bleu_brightness_set_request_t")
{
	uint struct_size;
	ZString device;
	Level level;
	brightness::Policy policy;
	ulong transition_ms;
}

<*
 A brightness service. Opaque: use the functions. Callable from any thread. A
 listener of the same handle must not call into it; such a call returns INVALID_STATE.
*>
// capi:opaque
struct BrightnessHandle @export("bleu_brightness_t")
{
	brightness::Brightness* service;
	Mutex mutex;
	BrightnessWatch* watches;
	WatchToken next_watch_id;
	uint readers;
	String backend_name;
}

<*
 A listener registered with `bleu_brightness_watch`. It runs on the service's worker
 thread, and once on the calling thread for the current state at registration. It
 must return quickly, must not block, and must not call back into this service.
 The snapshot is a view valid only during the call; `bleu_snapshot_retain` keeps it.
*>
alias BrightnessListener = fn void(void* context, capi::CSnapshot* snapshot);

// One registered listener. Freed by `bleu_brightness_unwatch` or `bleu_brightness_close`.
struct BrightnessWatch
{
	BrightnessHandle* owner;
	WatchToken id;
	BrightnessListener callback;
	void* context;
	observe::WatchId{brightness::State} native;
	BrightnessWatch* next;
}

const capi::SnapshotOps BRIGHTNESS_SNAPSHOT = {
	.service = capi::Service.BRIGHTNESS,
	.retain = &brightness_snapshot_retain,
	.release = &brightness_snapshot_release,
	.generation = &brightness_snapshot_generation,
	.json = &brightness_snapshot_json,
};

const capi::PacketOps BRIGHTNESS_PACKET = {
	.service = capi::Service.BRIGHTNESS,
	.release = &brightness_packet_release,
};

const capi::ReaderOps BRIGHTNESS_READER = {
	.service = capi::Service.BRIGHTNESS,
	.next = &brightness_reader_next,
	.take_dropped = &brightness_reader_take_dropped,
	.release = &brightness_reader_release,
	.packets = &BRIGHTNESS_PACKET,
};

const capi::OperationOps BRIGHTNESS_OPERATION = {
	.service = capi::Service.BRIGHTNESS,
	.wait = &brightness_operation_wait,
	.cancel = &brightness_operation_cancel,
	.phase = &brightness_operation_phase,
	.detail = &brightness_operation_detail,
	.value = &brightness_operation_value,
	.release = &brightness_operation_release,
};

fn void brightness_snapshot_retain(void* native)
{
	Snapshot{brightness::State}* snapshot = (Snapshot{brightness::State}*)native;
	snapshot.retain();
}

fn void brightness_snapshot_release(void* native)
{
	Snapshot{brightness::State}* snapshot = (Snapshot{brightness::State}*)native;
	snapshot.release();
}

fn ulong brightness_snapshot_generation(void* native)
{
	Snapshot{brightness::State}* snapshot = (Snapshot{brightness::State}*)native;
	return snapshot.generation;
}

fn String? brightness_snapshot_json(void* native, Allocator allocator)
{
	Snapshot{brightness::State}* snapshot = (Snapshot{brightness::State}*)native;
	return json::to_json(allocator, snapshot.value);
}

fn void*? brightness_reader_next(void* native, Duration timeout)
{
	stream::Reader{brightness::Event}* reader = (stream::Reader{brightness::Event}*)native;
	Snapshot{brightness::Event}* packet       = reader.next(timeout)!;
	return (void*)packet;
}

fn ulong brightness_reader_take_dropped(void* native)
{
	stream::Reader{brightness::Event}* reader = (stream::Reader{brightness::Event}*)native;
	return reader.take_dropped();
}

fn void brightness_reader_release(void* native)
{
	stream::Reader{brightness::Event}* reader = (stream::Reader{brightness::Event}*)native;
	reader.release();
}

fn void brightness_packet_release(void* native)
{
	Snapshot{brightness::Event}* packet = (Snapshot{brightness::Event}*)native;
	packet.release();
}

fn void? brightness_operation_wait(void* native, Duration timeout)
{
	brightness::SetOperation* operation = (brightness::SetOperation*)native;
	operation.wait(timeout)!;
}

fn void brightness_operation_cancel(void* native)
{
	brightness::SetOperation* operation = (brightness::SetOperation*)native;
	operation.cancel();
}

fn capi::OperationPhase brightness_operation_phase(void* native)
{
	brightness::SetOperation* operation = (brightness::SetOperation*)native;
	return capi::phase_from_ordinal(operation.phase().ordinal);
}

fn error::Detail* brightness_operation_detail(void* native)
{
	brightness::SetOperation* operation = (brightness::SetOperation*)native;
	return operation.detail();
}

fn void* brightness_operation_value(void* native)
{
	brightness::SetOperation* operation = (brightness::SetOperation*)native;
	return &operation.value;
}

fn void brightness_operation_release(void* native)
{
	brightness::SetOperation* operation = (brightness::SetOperation*)native;
	operation.release();
}

// A reader on this handle is gone: the handle may close again once none are left.
fn void brightness_reader_done(void* owner)
{
	BrightnessHandle* handle = (BrightnessHandle*)owner;
	handle.mutex.lock()!!;
	handle.readers--;
	handle.mutex.unlock();
}

// The listener the observable calls: it wraps the snapshot as a view and enters the callback mark.
fn void brightness_listener(void* context, Snapshot{brightness::State}* snapshot)
{
	BrightnessWatch* watch = (BrightnessWatch*)context;
	capi::CSnapshot view   = capi::view_of(&BRIGHTNESS_SNAPSHOT, snapshot);
	void* previous         = capi::enter_callback(watch.owner);
	defer capi::leave_callback(previous);
	watch.callback(watch.context, &view);
}

// Unlink and return the watch with `id`, or null.
fn BrightnessWatch* remove_brightness_watch(BrightnessWatch** head, capi::WatchToken id)
{
	BrightnessWatch** link = head;
	while (*link)
	{
		BrightnessWatch* watch = *link;
		if (watch.id == id)
		{
			*link = watch.next;
			return watch;
		}
		link = &watch.next;
	}
	return null;
}

fn void free_brightness_watches(BrightnessWatch* watch)
{
	while (watch)
	{
		BrightnessWatch* next = watch.next;
		alloc::free(mem, watch);
		watch = next;
	}
}

<*
 Open a brightness service. Pass NULL for the defaults. Release the handle with
 `bleu_brightness_close`.
*>
fn capi::CStatus bleu_brightness_open(
	BrightnessOptions* options,
	BrightnessHandle** out
) @export("bleu_brightness_open")
{
	capi::@capi_entry()
	{
		if (!out) return capi::argument_error("out must not be NULL");
		*out = null;
		BrightnessOptions given = { };
		if (options)
		{
			capi::CStatus status = capi::take_options(&given, BrightnessOptions::size, options, options.struct_size);
			if (status != capi::CStatus.OK) return status;
		}
		if (given.poll_ms > capi::MAX_MILLISECONDS) return capi::argument_error("poll_ms is longer than one year");
		if (given.transition_step_ms > capi::MAX_MILLISECONDS) return capi::argument_error(
			"transition_step_ms is longer than one year"
		);
		brightness::Options native = {
			.backend = given.backend,
			.poll = (Duration)(given.poll_ms * 1000),
			.transition_step = (Duration)(given.transition_step_ms * 1000),
			.root = capi::text_of(given.root),
			.bus_address = capi::text_of(given.bus_address),
		};
		brightness::Brightness*? opened = brightness::open(mem, native);
		if (catch err = opened) return capi::report(err, "the brightness service could not be opened");
		BrightnessHandle* handle = alloc::new(mem, BrightnessHandle);
		*handle = { .service = opened, .backend_name = opened.backend_name().copy(mem) };
		handle.mutex.init()!!;
		*out = handle;
		return capi::CStatus.OK;
	};
}

<*
 Stop the service and free the handle. Fails with INVALID_STATE, and leaves the
 handle usable, while readers obtained from it are not yet released. Listeners
 are removed; requests still running fail with DISCONNECTED or CANCELLED.
*>
fn capi::CStatus bleu_brightness_close(BrightnessHandle* handle) @export("bleu_brightness_close")
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
		BrightnessWatch* watches = handle.watches;
		handle.watches = null;
		handle.mutex.unlock();
		handle.service.close();
		alloc::free(mem, handle.backend_name.ptr);
		free_brightness_watches(watches);
		handle.mutex.destroy();
		alloc::free(mem, handle);
		return capi::CStatus.OK;
	};
}

<* The name of the backend in use ("linux", "win32", "macos"). Free it with `bleu_free`. *>
fn capi::CStatus bleu_brightness_backend_name(
	BrightnessHandle* handle,
	char** out,
	usz* len
) @export("bleu_brightness_backend_name")
{
	capi::@capi_entry()
	{
		if (!handle || !out || !len) return capi::argument_error("handle, out and len must not be NULL");
		return capi::copy_out(handle.backend_name, out, len);
	};
}

<* Whether a capability works with this backend, and if not, why. *>
fn capi::CStatus bleu_brightness_capability(
	BrightnessHandle* handle,
	brightness::Cap cap,
	capi::Capability* out
) @export("bleu_brightness_capability")
{
	capi::@capi_entry()
	{
		if (!handle || !out) return capi::argument_error("handle and out must not be NULL");
		if ((usz)cap.ordinal > (usz)brightness::Cap.TRANSITION.ordinal) return capi::argument_error(
			"unknown capability"
		);
		capi::fill_capability(out, handle.service.capability(cap));
		return capi::CStatus.OK;
	};
}

<* Ask the backend to re-read the hardware now. *>
fn capi::CStatus bleu_brightness_refresh(BrightnessHandle* handle) @export("bleu_brightness_refresh")
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
fn capi::CStatus bleu_brightness_snapshot(
	BrightnessHandle* handle,
	capi::CSnapshot** out
) @export("bleu_brightness_snapshot")
{
	capi::@capi_entry()
	{
		if (!handle || !out) return capi::argument_error("handle and out must not be NULL");
		if (capi::is_inside_callback(handle)) return capi::reentry_refused();
		*out = null;
		Snapshot{brightness::State}*? latest = handle.service.latest();
		if (catch err = latest) return capi::report(err, "the brightness state has not been read yet");
		*out = capi::new_snapshot(&BRIGHTNESS_SNAPSHOT, latest, true);
		return capi::CStatus.OK;
	};
}

<*
 The newest state as JSON, the same text `bleu_snapshot_json` gives for a snapshot.
 Free the buffer with `bleu_free`.
*>
fn capi::CStatus bleu_brightness_snapshot_json(
	BrightnessHandle* handle,
	char** out,
	usz* len
) @export("bleu_brightness_snapshot_json")
{
	capi::@capi_entry()
	{
		if (!handle || !out || !len) return capi::argument_error("handle, out and len must not be NULL");
		if (capi::is_inside_callback(handle)) return capi::reentry_refused();
		Snapshot{brightness::State}*? latest = handle.service.latest();
		if (catch err = latest) return capi::report(err, "the brightness state has not been read yet");
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
fn capi::CStatus bleu_brightness_wait(
	BrightnessHandle* handle,
	ulong seen,
	long timeout_ms,
	capi::CSnapshot** out
) @export("bleu_brightness_wait")
{
	capi::@capi_entry()
	{
		if (!handle || !out) return capi::argument_error("handle and out must not be NULL");
		if (timeout_ms < -1) return capi::argument_error("timeout_ms must be -1 or more");
		if (capi::is_inside_callback(handle)) return capi::reentry_refused();
		*out = null;
		Snapshot{brightness::State}*? next = handle.service.wait_after(seen, capi::wait_duration(timeout_ms));
		if (catch err = next) return capi::report(err, "no newer brightness state: timed out or the service closed");
		*out = capi::new_snapshot(&BRIGHTNESS_SNAPSHOT, next, true);
		return capi::CStatus.OK;
	};
}

<*
 The state a snapshot holds, borrowed until that snapshot is released. Returns NULL
 for a snapshot of another service.
*>
fn brightness::State* bleu_brightness_snapshot_state(
	capi::CSnapshot* snapshot
) @export("bleu_brightness_snapshot_state")
{
	foreign::@foreign_entry()
	{
		if (!snapshot || snapshot.service != capi::Service.BRIGHTNESS) return null;
		Snapshot{brightness::State}* state = (Snapshot{brightness::State}*)snapshot.native;
		return &state.value;
	};
}

<*
 Register a listener; `out_id` receives the id for `bleu_brightness_unwatch`. The
 listener runs on the worker thread for every later state, and once immediately on
 this thread for the current one.
*>
fn capi::CStatus bleu_brightness_watch(
	BrightnessHandle* handle,
	BrightnessListener callback,
	void* context,
	capi::WatchToken* out_id
) @export("bleu_brightness_watch")
{
	capi::@capi_entry()
	{
		if (!handle || !callback || !out_id) return capi::argument_error(
			"handle, callback and out_id must not be NULL"
		);
		if (capi::is_inside_callback(handle)) return capi::reentry_refused();
		BrightnessWatch* watch = alloc::new(mem, BrightnessWatch);
		*watch = { .owner = handle, .callback = callback, .context = context };
		handle.mutex.lock()!!;
		watch.id = ++handle.next_watch_id;
		handle.mutex.unlock();
		watch.native = handle.service.watch(&brightness_listener, watch);
		handle.mutex.lock()!!;
		watch.next = handle.watches;
		handle.watches = watch;
		handle.mutex.unlock();
		*out_id = watch.id;
		return capi::CStatus.OK;
	};
}

<* Remove a listener. When this returns, the listener is not running and will not run again. *>
fn capi::CStatus bleu_brightness_unwatch(
	BrightnessHandle* handle,
	capi::WatchToken id
) @export("bleu_brightness_unwatch")
{
	capi::@capi_entry()
	{
		if (!handle) return capi::argument_error("handle must not be NULL");
		if (capi::is_inside_callback(handle)) return capi::reentry_refused();
		handle.mutex.lock()!!;
		BrightnessWatch* found = remove_brightness_watch(&handle.watches, id);
		handle.mutex.unlock();
		if (!found) return capi::report(NOT_FOUND, "no listener has this id");
		if (catch err = handle.service.unwatch(found.native))
		{
			// The listener is still registered: keep its node, so that it can still be removed later.
			handle.mutex.lock()!!;
			found.next = handle.watches;
			handle.watches = found;
			handle.mutex.unlock();
			return capi::report(err, "the listener could not be removed");
		}
		alloc::free(mem, found);
		return capi::CStatus.OK;
	};
}

<*
 Subscribe to brightness events (level changes, devices added or removed). Read them
 with `bleu_reader_next`; release the reader before closing the handle.
*>
fn capi::CStatus bleu_brightness_subscribe(
	BrightnessHandle* handle,
	capi::CReader** out
) @export("bleu_brightness_subscribe")
{
	capi::@capi_entry()
	{
		if (!handle || !out) return capi::argument_error("handle and out must not be NULL");
		if (capi::is_inside_callback(handle)) return capi::reentry_refused();
		*out = null;
		stream::Reader{brightness::Event}*? reader = handle.service.subscribe();
		if (catch err = reader) return capi::report(err, "the brightness service is closed");
		handle.mutex.lock()!!;
		handle.readers++;
		handle.mutex.unlock();
		capi::CReader* result = alloc::new(mem, capi::CReader);
		*result = {
			.ops = &BRIGHTNESS_READER,
			.native = reader,
			.owner = handle,
			.owner_release = &brightness_reader_done
		};
		*out = result;
		return capi::CStatus.OK;
	};
}

<* The event carried by a packet from `bleu_brightness_subscribe`. Borrowed until the packet is released. *>
fn brightness::Event* bleu_brightness_packet_event(capi::CPacket* packet) @export("bleu_brightness_packet_event")
{
	foreign::@foreign_entry()
	{
		if (!packet || packet.ops.service != capi::Service.BRIGHTNESS) return null;
		Snapshot{brightness::Event}* event = (Snapshot{brightness::Event}*)packet.native;
		return &event.value;
	};
}

<*
 Ask for a device's light to be set. Returns at once with an operation: wait for it
 with `bleu_operation_wait`, read the result with `bleu_brightness_set_result`, and
 release it with `bleu_operation_release`.
*>
fn capi::CStatus bleu_brightness_set_level(
	BrightnessHandle* handle,
	BrightnessSetRequest* request,
	capi::COperation** out
) @export("bleu_brightness_set_level")
{
	capi::@capi_entry()
	{
		if (!handle || !request || !out) return capi::argument_error("handle, request and out must not be NULL");
		if (capi::is_inside_callback(handle)) return capi::reentry_refused();
		*out = null;
		BrightnessSetRequest given = { };
		capi::CStatus status = capi::take_options(&given, BrightnessSetRequest::size, request, request.struct_size);
		if (status != capi::CStatus.OK) return status;
		if (!given.device) return capi::argument_error("device must not be NULL");
		brightness::SetOperation*? operation = handle.service.set_level(
			capi::text_of(given.device),
			unit::level((float)given.level),
			given.policy,
			(Duration)(given.transition_ms * 1000)
		);
		if (catch err = operation) return capi::report(err, "the brightness request was refused");
		*out = capi::new_operation(&BRIGHTNESS_OPERATION, operation);
		return capi::CStatus.OK;
	};
}

<*
 The value a finished `bleu_brightness_set_level` operation wrote. NULL unless the
 operation has succeeded. Borrowed until the operation is released.
*>
fn brightness::Applied* bleu_brightness_set_result(capi::COperation* operation) @export("bleu_brightness_set_result")
{
	foreign::@foreign_entry()
	{
		if (!operation || operation.ops.service != capi::Service.BRIGHTNESS) return null;
		if (operation.ops.phase(operation.native) != capi::OperationPhase.SUCCEEDED) return null;
		return (brightness::Applied*)operation.ops.value(operation.native);
	};
}

<*
 The device at `index` of a brightness state, or NULL when `index` is out of range.
 The pointer is borrowed like the state it came from.
*>
fn brightness::Device* bleu_brightness_device_at(
	brightness::State* state,
	usz index
) @export("bleu_brightness_device_at")
{
	foreign::@foreign_entry()
	{
		if (!state || index >= state.devices.len) return null;
		return &state.devices[index];
	};
}

<*
 The control at `index` of a device, or NULL when `index` is out of range. Controls are
 in preference order: the order a request tries them in.
*>
fn brightness::Control* bleu_brightness_control_at(
	brightness::Device* device,
	usz index
) @export("bleu_brightness_control_at")
{
	foreign::@foreign_entry()
	{
		if (!device || index >= device.controls.len) return null;
		return &device.controls[index];
	};
}