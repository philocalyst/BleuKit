<*
 The network service: open it, read `latest()`, wait for changes, ask for
 things with operations.

 Network* network = network::open(mem)!;
 defer network.close();
 ConnectOp* op = network.connect({ .ssid = "Office", .passphrase = "correct horse battery" })!;
 defer op.release();
 Connected joined = op.wait(time::sec(60))!;

 Every method may be called from any thread. Requests that can fail or take
 time return an operation: the caller releases it when done, and the worker
 completes it exactly once.
*>
module bleu::network;
import std::collections::enummap, std::time, bleu::availability, bleu::error, bleu::observe, bleu::operation, bleu::stream, bleu::service;

alias NetworkHub = Hub{State, Command, Event};
alias Capabilities = EnumMap{Cap, Availability};

<* Default period of the periodic re-read, in microseconds (time::sec() cannot initialise a global). *>
const Duration DEFAULT_POLL = (Duration)5_000_000;

<* Most commands that may wait for the worker of one service. *>
const usz COMMAND_QUEUE = 256;

<*
 Longest wait for a backend's first publication when opening. The backend
 publishes after its setup (bus, secret agent), so this bounds that setup.
*>
const Duration OPEN_TIMEOUT = (Duration)60_000_000;

<*
 A Wi-Fi connection request. The backend decides the key management from the
 last scan; `passphrase` is "" for open networks and for networks whose saved
 profile already holds the secret.
*>
struct ConnectRequest
{
	char[] ssid; // raw octets, 1..32
	String passphrase; // "" or 8..255 characters, as the network requires
	bool autoconnect; // join this network automatically later (saved profile)
}

<* The service: one backend, one worker thread, one published state. *>
struct Network
{
	Allocator allocator;
	NetworkHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
}

<*
 Open the first working backend of this platform (or the one in `options`).

 @param allocator : "Allocator for the service and its snapshots"
 @return? error::UNAVAILABLE : "No backend works here (no network manager, no Wi-Fi API)"
 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
*>
fn Network*? open(Allocator allocator, Options options = { })
{
	if (options.poll == time::DURATION_ZERO) options.poll = DEFAULT_POLL;
	Network* self = alloc::new(allocator, Network);
	self.allocator = allocator;
	fault failure = error::UNAVAILABLE;
	bool matched  = false;
	foreach (driver : platform_drivers())
	{
		if (options.backend != AUTO && options.backend != driver.id) continue;
		matched = true;
		if (!driver.probe(&options)) continue;
		void*? created = driver.create(allocator, options, &self.capabilities);
		if (catch err = created)
		{
			failure = err; // this backend is present but did not start: try the next one
			continue;
		}
		self.driver = driver;
		self.driver_state = created;
		if (catch err = self.hub.start(
			allocator,
			"network",
			driver.info.name,
			driver.run,
			self.driver_state,
			COMMAND_QUEUE,
			&abandon_command
		))
		{
			driver.destroy(allocator, self.driver_state);
			alloc::free(allocator, self);
			return err~;
		}
		// The backend publishes once its setup is done, so its capabilities are final from here on.
		if (catch err = self.await_first_state())
		{
			self.hub.stop();
			driver.destroy(allocator, self.driver_state);
			alloc::free(allocator, self);
			return err~;
		}
		return self;
	}
	alloc::free(allocator, self);
	if (!matched && options.backend != AUTO) return error::UNSUPPORTED~;
	return failure~;
}

<* Stop the backend, release its state and every snapshot the hub still holds. *>
fn void Network.close(&self)
{
	self.hub.stop();
	self.driver.destroy(self.allocator, self.driver_state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend in use, for diagnostics ("networkmanager", "corewlan", "wlanapi"). *>
fn String Network.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Network.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The backend has not produced its first reading yet"
*>
fn Snapshot{State}*? Network.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`, then pass
 the previous snapshot's `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn Snapshot{State}*? Network.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later state. Quick and non-blocking only. *>
fn WatchId{State} Network.watch(
	&self,
	Listener{State} listener,
	void* context
) => self.hub.state.watch(listener, context);

<*
 Remove a listener; when this returns it is not running.

 @return? error::INVALID_STATE : "Called from inside the listener it would remove (or one it runs inside)"
*>
fn void? Network.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<* Subscribe to transient events. Overflow is reported by `Reader.take_dropped`: re-read the state then. *>
fn Reader{Event}*? Network.subscribe(&self) => self.hub.events.subscribe();

<* Ask the backend to re-read the platform now; returns once the request is queued. *>
fn void? Network.refresh(&self) => self.hub.post({ .kind = REFRESH });

<*
 Answer a CREDENTIALS_WANTED event with the passphrase the user typed. The
 network's connection then proceeds. Completes CHANGED when the answer is
 delivered, NOT_FOUND when no request has that id (it was already answered,
 cancelled or withdrawn).

 @param request : "The id of the CREDENTIALS_WANTED event"
 @param secret : "The passphrase, 1 to 255 characters"
 @return? error::INVALID_ARGUMENT : "The passphrase is empty or longer than 255 characters"
 @return? error::UNSUPPORTED : "This backend does not ask for credentials"
*>
fn SettleOp*? Network.supply_credentials(&self, ulong request, String secret)
{
	if (secret.len == 0 || secret.len > SECRET_MAX) return error::INVALID_ARGUMENT~;
	self.require(WIFI_SECRET_PROMPT)!;
	Command command = { .kind = SUPPLY_CREDENTIALS, .request = request };
	defer wipe_command_secret(&command);
	mem::copy(&command.secret.bytes, secret.ptr, secret.len);
	command.secret.len = secret.len;
	return self.submit_settle(command)!;
}

<*
 Refuse a CREDENTIALS_WANTED request: the connection it belongs to fails.
 Completes CHANGED when refused, NOT_FOUND when no request has that id.

 @return? error::UNSUPPORTED : "This backend does not ask for credentials"
*>
fn SettleOp*? Network.cancel_credentials(&self, ulong request)
{
	self.require(WIFI_SECRET_PROMPT)!;
	return self.submit_settle({ .kind = CANCEL_CREDENTIALS, .request = request })!;
}

<*
 Scan for networks. Completes when the platform reports a finished scan; the
 operation fails with TIMEOUT when the scan does not finish in time.

 @return? error::UNSUPPORTED : "This backend cannot scan"
*>
fn SettleOp*? Network.scan(&self)
{
	self.require(WIFI_SCAN)!;
	return self.submit_settle({ .kind = SCAN })!;
}

<*
 Connect to a Wi-Fi network. With an empty passphrase the saved profile is
 used. A network with no saved profile and no passphrase fails with AUTH_REQUIRED
 (on the operation); a passphrase that the network refuses fails with AUTH_REQUIRED
 too, and `State.wifi.failure` tells the two apart (AUTH_REQUIRED or AUTH_REJECTED).
 A saved profile keeps its autoconnect setting; `autoconnect` applies to a new one.

 @param request : "The network, its passphrase (if any) and whether a new profile joins automatically"
 @return? error::INVALID_ARGUMENT : "The SSID is empty or longer than 32 octets, or the passphrase is longer than 255 characters"
 @return? error::UNSUPPORTED : "This backend cannot connect with the requested credentials"
 @return? error::UNAVAILABLE : "There is no Wi-Fi interface, or its radio is off"
 @return? error::PERMISSION_DENIED : "macOS withholds the network names: Location Services must authorize this app (the operation's detail says how)"
 @return? NOT_FOUND : "The network is not in the last scan"
*>
fn ConnectOp*? Network.connect(&self, ConnectRequest request)
{
	if (request.ssid.len == 0 || request.ssid.len > SSID_MAX) return error::INVALID_ARGUMENT~;
	if (request.passphrase.len > SECRET_MAX) return error::INVALID_ARGUMENT~;
	self.require(request.passphrase.len > 0 ? WIFI_CONNECT_PSK : WIFI_CONNECT_OPEN)!;
	Command command = { .kind = CONNECT, .flag = request.autoconnect };
	defer wipe_command_secret(&command);
	copy_ssid(&command.ssid, request.ssid);
	if (request.passphrase.len > 0)
	{
		mem::copy(&command.secret.bytes, request.passphrase.ptr, request.passphrase.len);
		command.secret.len = request.passphrase.len;
	}
	return self.submit_connect(command)!;
}

<*
 Disconnect the Wi-Fi interface. Completes ALREADY when nothing was connected.

 @return? error::UNSUPPORTED : "This backend cannot disconnect"
*>
fn SettleOp*? Network.disconnect(&self)
{
	self.require(WIFI_DISCONNECT)!;
	return self.submit_settle({ .kind = DISCONNECT })!;
}

<*
 Forget the saved network with this SSID. Completes with NOT_FOUND on the
 operation when no saved network has it.

 @return? error::INVALID_ARGUMENT : "The SSID is empty or longer than 32 octets"
 @return? error::UNSUPPORTED : "This backend cannot forget networks"
*>
fn SettleOp*? Network.forget(&self, char[] ssid)
{
	if (ssid.len == 0 || ssid.len > SSID_MAX) return error::INVALID_ARGUMENT~;
	self.require(WIFI_FORGET)!;
	Command command = { .kind = FORGET };
	copy_ssid(&command.ssid, ssid);
	return self.submit_settle(command)!;
}

<*
 Switch the Wi-Fi radio on or off. Completes when the platform reports the new value.

 @return? error::UNSUPPORTED : "This backend cannot switch the radio"
*>
fn SettleOp*? Network.set_radio(&self, bool enabled)
{
	self.require(WIFI_RADIO)!;
	return self.submit_settle({ .kind = SET_RADIO, .flag = enabled })!;
}

<*
 Whether the saved network with this SSID joins automatically. Completes
 ALREADY when it is set that way, NOT_FOUND when no saved network has the SSID.

 @return? error::INVALID_ARGUMENT : "The SSID is empty or longer than 32 octets"
 @return? error::UNSUPPORTED : "This backend cannot change autoconnect"
*>
fn SettleOp*? Network.set_autoconnect(&self, char[] ssid, bool enabled)
{
	if (ssid.len == 0 || ssid.len > SSID_MAX) return error::INVALID_ARGUMENT~;
	self.require(WIFI_AUTOCONNECT)!;
	Command command = { .kind = SET_AUTOCONNECT, .flag = enabled };
	copy_ssid(&command.ssid, ssid);
	return self.submit_settle(command)!;
}

// Wait for the backend's first publication and release it: the backend publishes once its setup is done.
fn void? Network.await_first_state(&self)
{
	Snapshot{State}* first = self.hub.state.wait_after(0, OPEN_TIMEOUT)!;
	first.release();
}

// Fails with the capability's own reason when this backend lacks `cap`.
fn void? Network.require(&self, Cap cap)
{
	Availability available = self.capabilities.values[cap.ordinal];
	if (!available.ok()) return available.refusal()~;
}

// Create an operation, give the command its own reference, and queue the command.
fn SettleOp*? Network.submit_settle(&self, Command command)
{
	SettleOp* op = operation::begin{Settled}(self.allocator);
	op.retain();
	command.settle = op;
	if (catch err = self.hub.post(command))
	{
		op.release();
		op.release();
		return err~;
	}
	return op;
}

// As `submit_settle`, for connections, which report the joined network.
fn ConnectOp*? Network.submit_connect(&self, Command command)
{
	ConnectOp* op = operation::begin{Connected}(self.allocator);
	op.retain();
	command.connect = op;
	if (catch err = self.hub.post(command))
	{
		op.release();
		op.release();
		return err~;
	}
	return op;
}

<*
 Overwrite a command's secret with zeroes. Backends call it once a command is
 executed or abandoned; the caller's own copy is wiped by its `defer`.
*>
fn void wipe_command_secret(Command* command)
{
	mem::set(&command.secret.bytes, (char)0, SECRET_MAX);
	command.secret.len = 0;
}

<*
 Complete a command that will never run (the backend stopped, or returned early):
 its operation fails with DISCONNECTED and its secret is wiped. Runs on the worker
 thread after the backend's run function has returned, as `Hub.start` requires.
*>
fn void abandon_command(void* backend, Command* command)
{
	if (command.kind == CONNECT)
	{
		command.connect.fail(error::DISCONNECTED);
		command.connect.release();
	}
	else if (command.settle != null)
	{
		// REFRESH and SCAN_FINISHED carry no operation: nothing waits on them.
		command.settle.fail(error::DISCONNECTED);
		command.settle.release();
	}
	wipe_command_secret(command);
}

// Copy an SSID into a command's fixed buffer. The caller has checked the length.
fn void copy_ssid(SsidBuffer* buffer, char[] ssid) @local
{
	mem::copy(&buffer.bytes, ssid.ptr, ssid.len);
	buffer.len = ssid.len;
}