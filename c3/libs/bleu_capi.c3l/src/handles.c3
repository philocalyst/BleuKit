<*
 The handles every service hands out, type-erased: snapshots, event readers,
 event packets and operations. A handle holds a pointer to the service's native
 object plus a table of functions for that type (`*Ops`), so one C type serves
 every service. Each service supplies its table in its own `*_api.c3` file.
*>
module bleu::capi;
import std::thread, std::time, bleu::error, bleu::operation, bleu::stream, bleu::observe, bleu::json;

<* The service a handle belongs to; typed accessors check it before they cast. *>
enum Service : char
{
	BATTERY,
	BRIGHTNESS,
}

alias SnapshotRetainFn = fn void(void* native);
alias SnapshotReleaseFn = fn void(void* native);
alias SnapshotGenerationFn = fn ulong(void* native);
alias SnapshotJsonFn = fn String?(void* native, Allocator allocator);

<* Functions for one kind of snapshot; `native` is a `Snapshot{State}*`. *>
struct SnapshotOps
{
	Service service;
	SnapshotRetainFn retain;
	SnapshotReleaseFn release;
	SnapshotGenerationFn generation;
	SnapshotJsonFn json;
}

alias PacketReleaseFn = fn void(void* native);

<* Functions for one kind of event packet; `native` is a `Snapshot{Event}*`. *>
struct PacketOps
{
	Service service;
	PacketReleaseFn release;
}

alias ReaderNextFn = fn void*?(void* native, Duration timeout);
alias ReaderDroppedFn = fn ulong(void* native);
alias ReaderReleaseFn = fn void(void* native);
alias OwnerReleaseFn = fn void(void* owner);

<* Functions for one kind of event reader; `packets` are those of the packets it yields. *>
struct ReaderOps
{
	Service service;
	ReaderNextFn next;
	ReaderDroppedFn take_dropped;
	ReaderReleaseFn release;
	PacketOps* packets;
}

alias OperationWaitFn = fn void?(void* native, Duration timeout);
alias OperationCancelFn = fn void(void* native);
alias OperationPhaseFn = fn OperationPhase(void* native);
alias OperationDetailFn = fn error::Detail*(void* native);
alias OperationValueFn = fn void*(void* native);
alias OperationReleaseFn = fn void(void* native);

<* Functions for one kind of operation; `native` is an `Operation{Value}*`. *>
struct OperationOps
{
	Service service;
	OperationWaitFn wait;
	OperationCancelFn cancel;
	OperationPhaseFn phase;
	OperationDetailFn detail;
	OperationValueFn value;
	OperationReleaseFn release;
}

<*
 A retained, immutable state of one service. Everything reached from it stays valid
 until `bleu_snapshot_release`. A snapshot passed to a watch callback is only a
 view: it is valid during the call, and `bleu_snapshot_retain` makes an owned copy.
*>
// capi:opaque
struct CSnapshot @export("bleu_snapshot_t")
{
	Service service;
	bool owned;
	void* native;
	SnapshotOps* ops;
}

<* A stream of events from one service. Release it before closing the service. *>
// capi:opaque
struct CReader @export("bleu_reader_t")
{
	ReaderOps* ops;
	void* native;
	void* owner;
	OwnerReleaseFn owner_release;
}

<* One event, retained until `bleu_packet_release`. Read it with the service's `*_packet_event`. *>
// capi:opaque
struct CPacket @export("bleu_packet_t")
{
	PacketOps* ops;
	void* native;
}

<* A request that finishes later. Its result is read with the operation's typed accessor. *>
// capi:opaque
struct COperation @export("bleu_operation_t")
{
	OperationOps* ops;
	void* native;
}

// The service whose listener is running on this thread, so calls back into it can be refused.
tlocal void* callback_owner;

<* Mark a listener of `owner` as running on this thread; returns the previous mark. *>
fn void* enter_callback(void* owner)
{
	void* previous = callback_owner;
	callback_owner = owner;
	return previous;
}

<* Restore the mark that `enter_callback` returned. *>
fn void leave_callback(void* previous)
{
	callback_owner = previous;
}

<* Whether this thread is inside a listener of `owner`. *>
fn bool is_inside_callback(void* owner) => callback_owner == owner;

fn CSnapshot* new_snapshot(SnapshotOps* ops, void* native, bool owned)
{
	CSnapshot* snapshot = alloc::new(mem, CSnapshot);
	*snapshot = { .service = ops.service, .owned = owned, .native = native, .ops = ops };
	return snapshot;
}

fn CPacket* new_packet(PacketOps* ops, void* native)
{
	CPacket* packet = alloc::new(mem, CPacket);
	*packet = { .ops = ops, .native = native };
	return packet;
}

fn COperation* new_operation(OperationOps* ops, void* native)
{
	COperation* operation = alloc::new(mem, COperation);
	*operation = { .ops = ops, .native = native };
	return operation;
}

<*
 Make a read-only view of a snapshot that a listener is given. It is not owned:
 `bleu_snapshot_release` on it does nothing, and it is valid only during the call.
*>
fn CSnapshot view_of(SnapshotOps* ops, void* native)
{
	return { .service = ops.service, .owned = false, .native = native, .ops = ops };
}

<*
 Copy the status an operation or reader failed with onto the calling thread, with
 its native details, so that `bleu_last_error` describes it.
*>
fn void adopt_detail(error::Detail* detail)
{
	error::Detail* last = error::last();
	if (detail.len > 0) *last = *detail;
}

<*
 Copy a snapshot's state as JSON into a new buffer the caller frees with
 `bleu_free`. Works for every service, with no per-type binding.

 out: Receives the buffer; NUL-terminated, length in `len` excludes the NUL
 len: Receives the length of the JSON text in bytes
 Fails with INVALID_ARGUMENT: A pointer is NULL
*>
fn CStatus bleu_snapshot_json(CSnapshot* snapshot, char** out, usz* len) @export("bleu_snapshot_json")
{
	@capi_entry()
	{
		if (!snapshot || !out || !len) return argument_error("snapshot, out and len must not be NULL");
		String? text = snapshot.ops.json(snapshot.native, tmem);
		if (catch err = text) return report(err, "the snapshot could not be encoded as JSON");
		return copy_out(text, out, len);
	};
}

<* The generation of a snapshot: the number of the publication that produced it. *>
fn CStatus bleu_snapshot_generation(CSnapshot* snapshot, ulong* out) @export("bleu_snapshot_generation")
{
	@capi_entry()
	{
		if (!snapshot || !out) return argument_error("snapshot and out must not be NULL");
		*out = snapshot.ops.generation(snapshot.native);
		return CStatus.OK;
	};
}

<* Take another reference to a snapshot, as an owned handle; this works on watch views too. *>
fn CStatus bleu_snapshot_retain(CSnapshot* snapshot, CSnapshot** out) @export("bleu_snapshot_retain")
{
	@capi_entry()
	{
		if (!snapshot || !out) return argument_error("snapshot and out must not be NULL");
		snapshot.ops.retain(snapshot.native);
		*out = new_snapshot(snapshot.ops, snapshot.native, true);
		return CStatus.OK;
	};
}

<* Drop an owned snapshot; the last reference frees its state. Views are ignored. *>
fn void bleu_snapshot_release(CSnapshot* snapshot) @export("bleu_snapshot_release")
{
	@capi_scope()
	{
		if (!snapshot || !snapshot.owned) return;
		snapshot.ops.release(snapshot.native);
		alloc::free(mem, snapshot);
	};
}

<*
 Wait for the next event on a reader.

 timeout_ms: -1 waits forever, 0 only polls, otherwise milliseconds
 Fails with TIMEOUT: No event arrived in time
 Fails with DISCONNECTED: The service closed and the queue is empty
*>
fn CStatus bleu_reader_next(CReader* reader, long timeout_ms, CPacket** out) @export("bleu_reader_next")
{
	@capi_entry()
	{
		if (!reader || !out) return argument_error("reader and out must not be NULL");
		if (timeout_ms < -1) return argument_error("timeout_ms must be -1 or more");
		*out = null;
		void*? native = reader.ops.next(reader.native, wait_duration(timeout_ms));
		if (catch err = native) return report(err, "no event arrived: timed out or the service closed");
		*out = new_packet(reader.ops.packets, native);
		return CStatus.OK;
	};
}

<* The number of events this reader lost to overflow since it was last asked. *>
fn CStatus bleu_reader_take_dropped(CReader* reader, ulong* out) @export("bleu_reader_take_dropped")
{
	@capi_entry()
	{
		if (!reader || !out) return argument_error("reader and out must not be NULL");
		*out = reader.ops.take_dropped(reader.native);
		return CStatus.OK;
	};
}

<* Unsubscribe and free a reader. Its queued events are discarded. *>
fn void bleu_reader_release(CReader* reader) @export("bleu_reader_release")
{
	@capi_scope()
	{
		if (!reader) return;
		reader.ops.release(reader.native);
		if (reader.owner_release) reader.owner_release(reader.owner);
		alloc::free(mem, reader);
	};
}

<* Free an event packet. Read its fields before releasing it. *>
fn void bleu_packet_release(CPacket* packet) @export("bleu_packet_release")
{
	@capi_scope()
	{
		if (!packet) return;
		packet.ops.release(packet.native);
		alloc::free(mem, packet);
	};
}

<*
 Block until the operation finishes or `timeout_ms` passes (-1 waits forever, 0
 only polls). OK means it succeeded: read its result with the typed accessor.
 On failure the calling thread's last error holds the operation's native details.

 Fails with TIMEOUT: Still running; the operation carries on
 Fails with CANCELLED: The operation was cancelled
*>
fn CStatus bleu_operation_wait(COperation* operation, long timeout_ms) @export("bleu_operation_wait")
{
	@capi_entry()
	{
		if (!operation) return argument_error("operation must not be NULL");
		if (timeout_ms < -1) return argument_error("timeout_ms must be -1 or more");
		if (catch err = operation.ops.wait(operation.native, wait_duration(timeout_ms)))
		{
			adopt_detail(operation.ops.detail(operation.native));
			return report(err, "the operation did not succeed");
		}
		return CStatus.OK;
	};
}

<* Ask the operation to stop. It ends CANCELLED if it honours the request. *>
fn CStatus bleu_operation_cancel(COperation* operation) @export("bleu_operation_cancel")
{
	@capi_entry()
	{
		if (!operation) return argument_error("operation must not be NULL");
		operation.ops.cancel(operation.native);
		return CStatus.OK;
	};
}

<* The phase of an operation right now. *>
fn CStatus bleu_operation_phase(COperation* operation, OperationPhase* out) @export("bleu_operation_phase")
{
	@capi_entry()
	{
		if (!operation || !out) return argument_error("operation and out must not be NULL");
		*out = operation.ops.phase(operation.native);
		return CStatus.OK;
	};
}

<* The native details of a failed operation (or the calling thread's own record otherwise). *>
fn CStatus bleu_operation_detail(COperation* operation, ErrorDetail* out) @export("bleu_operation_detail")
{
	@capi_entry()
	{
		if (!operation || !out) return argument_error("operation and out must not be NULL");
		fill_detail(out, operation.ops.detail(operation.native));
		return CStatus.OK;
	};
}

<* Release an operation. A request still running keeps going, but nobody can read its result. *>
fn void bleu_operation_release(COperation* operation) @export("bleu_operation_release")
{
	@capi_scope()
	{
		if (!operation) return;
		operation.ops.release(operation.native);
		alloc::free(mem, operation);
	};
}