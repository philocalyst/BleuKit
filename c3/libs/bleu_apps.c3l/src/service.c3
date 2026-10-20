<*
 The application catalogue: open it, read `latest()`, launch apps, search.

 Apps* apps = apps::open(mem, {})!;
 defer apps.close();
 CatalogueSnapshot* snapshot = apps.latest()!;
 defer snapshot.release();
 // snapshot.value.apps is sorted by name
 LaunchOperation* op = apps.launch("org.example.Editor.desktop", { .uris = { "file:///tmp/a.txt" } })!;
 defer op.release();
 Launched started = op.wait(time::sec(5))!;

 Every method may be called from any thread.
*>
module bleu::apps;
import std::collections::enummap, std::time, bleu::error, bleu::availability, bleu::observe, bleu::operation, bleu::service, bleu::stream;

alias Capabilities = EnumMap{Cap, Availability};

const Duration DEFAULT_SETTLE = (Duration)200_000; // 200 ms of quiet before a rescan (microseconds)
const Duration DEFAULT_POLL   = (Duration)5_000_000; // 5 s between directory checks on polled backends

<* How `open` finds and tunes a backend. Zero or empty fields take their defaults. *>
struct Options
{
	Backend backend; // AUTO tries every backend of the platform in priority order
	Duration settle; // Linux: how long the catalogue directories must stay quiet before a rescan
	Duration poll; // polled backends: how often the directories are checked
	String root; // prefix for the Linux data directories; "" for the real system, a temporary tree in tests
	String[] terminals; // Linux: terminal emulators tried in order for `Terminal=true`; empty for the built-in list
	String icon_theme; // Linux: icon theme for `icon_file`; "" for "hicolor"
	String locale; // Linux: locale for localized names; "" to read it from the environment
}

<*
 The service. Not copyable: backends hold pointers into it.
*>
struct Apps
{
	Allocator allocator;
	AppsHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
}

<*
 The result of `search`: the catalogue it was computed on, and the matches in
 rank order. `hits[i].index` indexes `snapshot.value.apps`.
*>
struct Ranking
{
	Allocator allocator;
	CatalogueSnapshot* snapshot;
	SearchHit[] hits;
}

<* Release the snapshot and the hit list. *>
fn void Ranking.release(&self)
{
	self.snapshot.release();
	alloc::free(self.allocator, self.hits.ptr);
	*self = { };
}

<*
 Open the first working backend of this platform (or the one in `options`).

 @param allocator : "Allocator for the service and its snapshots"
 @return? error::UNAVAILABLE : "No backend works here (no application directories)"
 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
*>
fn Apps*? open(Allocator allocator, Options options = { })
{
	if (options.settle == time::DURATION_ZERO) options.settle = DEFAULT_SETTLE;
	if (options.poll == time::DURATION_ZERO) options.poll = DEFAULT_POLL;
	Driver* driver = select_driver(options)!;
	Apps* self     = alloc::new(allocator, Apps);
	self.allocator = allocator;
	self.driver = driver;
	self.driver_state = driver.create(allocator, options, &self.capabilities)!;
	if (catch err = self.hub.start(
		allocator,
		"apps",
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

<* Stop the backend and release everything. Launches still queued fail with `DISCONNECTED`. *>
fn void Apps.close(&self)
{
	self.hub.stop();
	self.driver.destroy(self.allocator, self.driver_state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend in use, for diagnostics ("xdg-desktop", "app-bundles", "start-menu"). *>
fn String Apps.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Apps.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest catalogue, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The backend has not produced its first listing yet"
*>
fn CatalogueSnapshot*? Apps.latest(&self) => self.hub.latest();

<*
 Block until a catalogue newer than `seen` exists. Start with `seen = 0`, then
 pass the previous snapshot's `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn CatalogueSnapshot*? Apps.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later catalogue. Quick and non-blocking only. *>
fn WatchId{State} Apps.watch(&self, Listener{State} listener, void* context) => self.hub.state.watch(listener, context);

<*
 Remove a listener; when this returns it is not running.

 @return? error::INVALID_STATE : "Called from inside the listener it would remove"
*>
fn void? Apps.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<* Subscribe to transient events (apps added, removed or changed). *>
fn Reader{Event}*? Apps.subscribe(&self) => self.hub.events.subscribe();

<* Ask the backend to rescan the catalogue now; returns once the request is queued. *>
fn void? Apps.refresh(&self) => self.hub.post({ .kind = REFRESH });

<*
 Start the app `app_id` (its desktop file ID, bundle identifier or shortcut path).

 The operation completes with the route taken and the child's pid. Launching
 an app that is not in the catalogue fails with `NOT_FOUND`.

 @param app_id : "The `App.id` to start"
 @return? error::UNAVAILABLE : "The service is closing"
 @return? error::BUSY : "Too many commands are waiting"
*>
fn LaunchOperation*? Apps.launch(&self, String app_id, LaunchOptions options = { })
{
	return submit(self, app_id, "", options);
}

<*
 Start a secondary action of an app (a desktop entry's `[Desktop Action X]`).

 @param action_id : "The `AppAction.id` within the app"
 @return? error::UNSUPPORTED : "This platform has no secondary actions"
 @return? error::UNAVAILABLE : "The service is closing"
 @return? error::BUSY : "Too many commands are waiting"
*>
fn LaunchOperation*? Apps.launch_action(&self, String app_id, String action_id, LaunchOptions options = { })
{
	return submit(self, app_id, action_id, options);
}

// Copy the submission, queue it for the worker and return the caller's reference to its operation.
fn LaunchOperation*? submit(Apps* self, String app_id, String action_id, LaunchOptions options) @local
{
	LaunchOperation* op    = operation::begin{Launched}(self.allocator);
	LaunchRequest* request = new_request(self.allocator, app_id, action_id, options, op.retain());
	if (catch err = self.hub.post({ .kind = LAUNCH, .request = request }))
	{
		request.release();
		op.release();
		return err~;
	}
	return op;
}

<*
 The file that draws the icon `icon` (an icon name or an absolute path) at
 `size` logical pixels and `scale`, or the path it is.

 @param allocator : "Allocator for the returned path"
 @return? NOT_FOUND : "No icon file of that name exists in the theme"
 @return? error::UNSUPPORTED : "This platform has no icon lookup in this service"
*>
fn String? Apps.icon_file(&self, String icon, int size, int scale, Allocator allocator)
{
	return self.driver.icon(self.driver_state, icon, size, scale, allocator);
}

<*
 Rank the catalogue against `query`. See `search.c3` for the rules.

 @param ranker : "Optional bonus per app (frecency, pinning); may be null"
 @param allocator : "Allocator for the hit list; `Ranking.release` frees it"
 @return? error::UNAVAILABLE : "The backend has not produced its first listing yet"
*>
fn Ranking? Apps.search(&self, String query, Ranker ranker, void* context, Allocator allocator)
{
	CatalogueSnapshot* snapshot = self.hub.latest()!;
	SearchHit[] hits            = rank(&snapshot.value, query, ranker, context, allocator);
	return { .allocator = allocator, .snapshot = snapshot, .hits = hits };
}