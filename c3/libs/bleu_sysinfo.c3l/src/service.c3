<*
 The sysinfo service: open it, read `latest()`, wait for changes, end processes.

 Sysinfo* sysinfo = sysinfo::open(mem)!!;
 defer sysinfo.close();
 if (try snapshot = sysinfo.latest())
 {
 defer snapshot.release();
 // snapshot.value.cpu.usage, snapshot.value.memory ...
 }

 The service samples on its own worker thread every `Options.interval` and
 publishes a new state only when something changed, so consumers never compute
 deltas. Every method may be called from any thread.
*>
module bleu::sysinfo;
import std::collections::enummap, std::time, bleu::availability, bleu::error, bleu::observe, bleu::operation, bleu::service, bleu::stream;

alias SysinfoHub = Hub{State, Command, Event};
alias Capabilities = EnumMap{Cap, Availability};

<*
 Sampling period when `Options.interval` is zero. One second is what a status
 bar shows; the CPU percentages are averages over the real time between samples.
*>
const Duration DEFAULT_INTERVAL = (Duration)1_000_000;

<*
 Shortest period accepted. CPU percentages need a window to average over, and
 a shorter one only adds noise (the same floor sysinfo uses, 200 ms).
*>
const Duration MINIMUM_INTERVAL = (Duration)200_000;

<* Busiest processes kept when `Options.process_count` is zero. *>
const uint DEFAULT_PROCESS_COUNT = 10;

<* How `open` finds and tunes a backend. *>
struct Options
{
	Backend backend; // AUTO tries every backend of the platform in priority order
	Duration interval; // sampling period; 0 means DEFAULT_INTERVAL, below MINIMUM_INTERVAL is refused
	uint process_count; // processes kept in `State.processes`; 0 means DEFAULT_PROCESS_COUNT
	String root; // Linux only: prefix for /proc, /sys and /etc, "" for the real system; tests use a fake tree
}

<* A running sysinfo service. Created by `open`, released by `close`. *>
struct Sysinfo
{
	Allocator allocator;
	SysinfoHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
}

<*
 Open the first working backend of this platform (or the one in `options`) and
 start sampling.

 @param allocator : "Allocator for the service and its snapshots"
 @param options : "Backend, sampling period, number of processes, and fake-root prefix"
 @return? error::UNAVAILABLE : "No backend works here"
 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
 @return? error::INVALID_ARGUMENT : "The interval is shorter than MINIMUM_INTERVAL"
*>
fn Sysinfo*? open(Allocator allocator, Options options = { })
{
	if (options.interval == time::DURATION_ZERO) options.interval = DEFAULT_INTERVAL;
	if (options.interval < MINIMUM_INTERVAL)
	{
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"interval is below the 200 ms minimum"
		)~;
	}
	if (options.process_count == 0) options.process_count = DEFAULT_PROCESS_COUNT;
	Driver* driver = select_driver(options)!;
	Sysinfo* self  = alloc::new(allocator, Sysinfo);
	self.allocator = allocator;
	self.driver = driver;
	self.driver_state = driver.create(allocator, options, &self.capabilities)!;
	if (catch err = self.hub.start(allocator, "sysinfo", driver.info.name, driver.run, self.driver_state))
	{
		driver.destroy(allocator, self.driver_state);
		alloc::free(allocator, self);
		return err~;
	}
	return self;
}

<* Stop the sampler and release everything. *>
fn void Sysinfo.close(&self)
{
	self.hub.stop();
	self.driver.destroy(self.allocator, self.driver_state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend in use, for diagnostics ("procfs", "mach", "win32"). *>
fn String Sysinfo.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Sysinfo.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The first sample has not been taken yet"
*>
fn Snapshot{State}*? Sysinfo.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`, then pass
 the previous snapshot's `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn Snapshot{State}*? Sysinfo.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later state. Quick and non-blocking only. *>
fn WatchId{State} Sysinfo.watch(
	&self,
	Listener{State} listener,
	void* context
) => self.hub.state.watch(listener, context);

<* Remove a listener; when this returns it is not running. Not from inside a listener. *>
fn void Sysinfo.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<* Subscribe to transient events (volumes and interfaces appearing or disappearing). *>
fn Reader{Event}*? Sysinfo.subscribe(&self) => self.hub.events.subscribe();

<*
 Ask the system to end process `pid`. The returned operation completes on the
 worker thread once the system has answered; a refusal such as a process owned by
 another account ends it `FAILED` with `error::PERMISSION_DENIED`.

 @return? error::UNSUPPORTED : "This backend cannot end processes"
 @return? error::INVALID_ARGUMENT : "The id is 0, is above MAX_TARGET_PID, names this process, or is init without FORCE"
 @return? error::UNAVAILABLE : "The request queue is closed or full"
*>
fn Operation{KillReceipt}*? Sysinfo.kill(&self, uint pid, KillMode mode)
{
	Availability availability = self.capability(PROCESS_KILL);
	if (!availability.ok()) return availability.refusal()~;
	check_kill_target(pid, mode, own_process_id())!;
	Operation{KillReceipt}* operation = operation::begin{KillReceipt}(self.allocator);
	// One reference for the caller, one for the worker, which releases its own when done.
	operation.retain();
	if (catch err = self.hub.post({ .pid = pid, .mode = mode, .operation = operation }))
	{
		operation.release();
		operation.release();
		return err~;
	}
	return operation;
}