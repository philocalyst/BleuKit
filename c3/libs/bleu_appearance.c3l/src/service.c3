<*
 The appearance service: open it, read `latest()`, wait for changes, ask for
 changes.

 Appearance* appearance = appearance::open(mem)!;
 defer appearance.close();
 if (try snapshot = appearance.latest())
 {
 defer snapshot.release();
 // snapshot.value.color_scheme, snapshot.value.accent ...
 }
 Operation{bool}* done = appearance.set_color_scheme(DARK)!;
 defer done.release();
 done.wait(time::sec(5))!;

 Every method may be called from any thread.
*>
module bleu::appearance;
import std::collections::enummap, std::time, bleu::availability, bleu::error, bleu::observe, bleu::operation, bleu::service, bleu::stream;

alias AppearanceHub = Hub{State, Command, Event};
alias Capabilities = EnumMap{Cap, Availability};

<* Polling backends re-read this often; 30 s. Change signals arrive without waiting for it. *>
const Duration DEFAULT_POLL = (Duration)30_000_000;

<* How `open` finds and tunes a backend. *>
struct Options
{
	Backend backend; // AUTO tries every backend of the platform in priority order
	Duration poll; // how often polling readings are refreshed; 0 means DEFAULT_POLL
	String bus_address; // Linux: the session bus to use; "" means the session environment
	String[] wallpaper_command; // Linux: argv that sets a wallpaper; each "{path}" is replaced. Empty: use GNOME gsettings
}

struct Appearance
{
	Allocator allocator;
	AppearanceHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
}

<*
 Open the first working backend of this platform (or the one in `options`).

 @param allocator : "Allocator for the service and its snapshots"
 @return? error::UNAVAILABLE : "No backend works here (no desktop settings answer)"
 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
*>
fn Appearance*? open(Allocator allocator, Options options = { })
{
	if (options.poll == time::DURATION_ZERO) options.poll = DEFAULT_POLL;
	Driver* driver   = select_driver(options)!;
	Appearance* self = alloc::new(allocator, Appearance);
	self.allocator = allocator;
	self.driver = driver;
	void*? state = driver.create(allocator, options, &self.capabilities);
	if (catch err = state)
	{
		alloc::free(allocator, self);
		return err~;
	}
	self.driver_state = state;
	if (catch err = self.hub.start(
		allocator,
		"appearance",
		driver.info.name,
		driver.run,
		self.driver_state,
		abandon: &abandon_command
	))
	{
		driver.destroy(allocator, self.driver_state);
		alloc::free(allocator, self);
		return err~;
	}
	return self;
}

<* Stop the backend and release everything. Queued requests fail with CANCELLED. *>
fn void Appearance.close(&self)
{
	self.hub.stop();
	self.driver.destroy(self.allocator, self.driver_state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend in use, for diagnostics ("portal", "gsettings", "appkit", "win32"). *>
fn String Appearance.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Appearance.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The backend has not produced its first reading yet"
*>
fn Snapshot{State}*? Appearance.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`, then pass
 the previous snapshot's `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn Snapshot{State}*? Appearance.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later state. Quick and non-blocking only. *>
fn WatchId{State} Appearance.watch(
	&self,
	Listener{State} listener,
	void* context
) => self.hub.state.watch(listener, context);

<*
 Remove a listener; when this returns it is not running.

 @return? error::INVALID_STATE : "Called from inside the listener it would remove"
*>
fn void? Appearance.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<* Subscribe to transient events (which part of the appearance changed). *>
fn Reader{Event}*? Appearance.subscribe(&self) => self.hub.events.subscribe();

<* Ask the backend to re-read the desktop now; returns once the request is queued. *>
fn void? Appearance.refresh(&self) => self.hub.post({ .kind = REFRESH });

<*
 Ask the desktop to switch between light and dark. The state changes when the
 desktop reports it, not when this operation succeeds.

 @return? error::UNSUPPORTED : "This platform or backend cannot set the colour scheme (see `capability`)"
 @return? error::PERMISSION_DENIED : "The desktop refused the change"
 @return? error::INVALID_ARGUMENT : "This platform cannot express NO_PREFERENCE"
*>
fn Operation{bool}*? Appearance.set_color_scheme(&self, ColorScheme scheme)
{
	Availability availability = self.capability(COLOR_SCHEME_SET);
	if (!availability.ok()) return availability.refusal()~;
	return self.submit({ .kind = SET_COLOR_SCHEME, .scheme = scheme }, "");
}

<*
 Set the desktop picture to the file at `path`, on every screen the desktop
 has one picture for. `path` must be absolute: "/..." on POSIX; "C:\..." or "\\server\share\..." on
 Windows.

 @return? error::UNSUPPORTED : "This backend cannot set the wallpaper (see `capability`)"
 @return? error::INVALID_ARGUMENT : "The path is not absolute on this platform"
*>
fn Operation{bool}*? Appearance.set_wallpaper(&self, String path)
{
	Availability availability = self.capability(WALLPAPER_SET);
	if (!availability.ok()) return availability.refusal()~;
	if (!is_absolute_path(path)) return error::raise(
		error::INVALID_ARGUMENT,
		error::Domain.INTERNAL,
		0,
		"wallpaper path '%s' is not absolute",
		path
	)~;
	return self.submit({ .kind = SET_WALLPAPER }, path);
}

// Queue a request. The operation is created here and the worker gets its own reference.
fn Operation{bool}*? Appearance.submit(&self, Command command, String path)
{
	Operation{bool}* op = operation::begin(self.allocator);
	command.path = path.copy(op.allocator());
	command.op = op.retain();
	if (catch err = self.hub.post(command))
	{
		op.release();
		op.release();
		return err~;
	}
	return op;
}