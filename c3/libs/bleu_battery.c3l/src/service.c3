<*
 The battery service: open it, read `latest()`, wait for changes.

 Battery* battery = battery::open(mem)!;
 defer battery.close();
 if (try snapshot = battery.latest())
 {
 defer snapshot.release();
 // snapshot.value.on_mains, snapshot.value.sources ...
 }

 Every method may be called from any thread.
*>
module bleu::battery;
import std::collections::enummap, std::time, bleu::error, bleu::availability, bleu::observe, bleu::stream, bleu::service;

alias BatteryHub = Hub{State, Command, Event};
alias Capabilities = EnumMap{Cap, Availability};

<* How `open` finds and tunes a backend. *>
struct Options
{
	Backend backend; // AUTO tries every backend of the platform in priority order
	Duration poll; // polling backends re-read this often; 0 means the default (5 s)
	String root; // prefix for kernel pseudo-files, "" for the real system; lets tests use a fake tree
}

const Duration DEFAULT_POLL = (Duration)5_000_000; // 5 s in microseconds (time::sec() cannot initialise a global)

struct Battery
{
	Allocator allocator;
	BatteryHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
	Startup startup;
}

<*
 Open the first working backend of this platform (or the one in `options`). Blocks
 until the backend's worker is running, so a backend that cannot start is an error here.

 @param allocator : "Allocator for the service and its snapshots"
 @return? error::UNAVAILABLE : "No backend works here (no battery subsystem), or the chosen one failed to start"
 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
*>
fn Battery*? open(Allocator allocator, Options options = { })
{
	if (options.poll == time::DURATION_ZERO) options.poll = DEFAULT_POLL;
	Driver* driver = select_driver(options)!;
	Battery* self  = alloc::new(allocator, Battery);
	self.allocator = allocator;
	self.driver = driver;
	self.startup.init();
	void*? state = driver.create(allocator, options, &self.capabilities, &self.startup);
	if (catch err = state)
	{
		self.startup.free();
		alloc::free(allocator, self);
		return err~;
	}
	self.driver_state = state;
	if (catch err = self.hub.start(
		allocator,
		"battery",
		driver.info.name,
		driver.run,
		self.driver_state,
		service::DEFAULT_QUEUE{State, Command, Event},
		&abandon
	))
	{
		driver.destroy(allocator, self.driver_state);
		self.startup.free();
		alloc::free(allocator, self);
		return err~;
	}
	if (catch err = self.startup.wait())
	{
		self.close();
		return err~;
	}
	return self;
}

<* Stop the backend and release everything. *>
fn void Battery.close(&self)
{
	self.hub.free();
	self.driver.destroy(self.allocator, self.driver_state);
	self.startup.free();
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<*
 Called for each command still queued when the backend stops. REFRESH carries no
 `Operation`, so nothing waits on it and there is nothing to complete.
*>
fn void abandon(void* backend, Command* command) @local
{
}

<* Name of the backend in use, for diagnostics ("sysfs", "upower", "iokit", "win32"). *>
fn String Battery.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Battery.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The backend has not produced its first reading yet"
*>
fn Snapshot{State}*? Battery.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`, then pass
 the previous snapshot's `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn Snapshot{State}*? Battery.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later state. Quick and non-blocking only. *>
fn WatchId{State} Battery.watch(
	&self,
	Listener{State} listener,
	void* context
) => self.hub.state.watch(listener, context);

<*
 Remove a listener; when this returns it is not running.

 @return? error::INVALID_STATE : "Called from inside the listener it would remove"
*>
fn void? Battery.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<* Subscribe to transient events (sources added/removed, mains changed). *>
fn Reader{Event}*? Battery.subscribe(&self) => self.hub.events.subscribe();

<* Ask the backend to re-read the hardware now; returns once the request is queued. *>
fn void? Battery.refresh(&self) => self.hub.post(REFRESH);