<*
 The audio service: open it, read `latest()`, wait for changes, ask for changes.

 Audio* audio = audio::open(mem)!;
 defer audio.close();
 if (try snapshot = audio.latest())
 {
 defer snapshot.release();
 // snapshot.value.outputs, snapshot.value.default_output ...
 }
 Pending* done = audio.set_device_volume(OUTPUT, id, gains)!;
 done.wait(time::ms(500))!;

 Every method may be called from any thread. Commands complete when the server
 has answered; the change itself is seen in the next state.
*>
module bleu::audio;
import std::collections::enummap, std::time, bleu::error, bleu::availability, bleu::observe, bleu::stream, bleu::service, bleu::operation, bleu::unit, bleu::rt::worker;

alias AudioHub = Hub{State, Command, Event};
alias Capabilities = EnumMap{Cap, Availability};

<*
 How `open` finds and reaches the audio system. `server` is the PulseAudio
 socket path, "" to find it from PULSE_SERVER or the runtime directory.
 `cookie_file` is the authentication cookie, "" to find it from PULSE_COOKIE
 or the configuration directory. Both are ignored by the other backends.
*>
struct Options
{
	Backend backend;
	String server;
	String cookie_file;
}

<* The open service. Its worker thread runs until `close`. *>
struct Audio
{
	Allocator allocator;
	AudioHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
}

<*
 Open the first working backend of this platform (or the one in `options`).

 @param allocator : "Allocator for the service and its snapshots"
 @return? error::UNAVAILABLE : "No backend works here (no audio server is running)"
 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
*>
fn Audio*? open(Allocator allocator, Options options = { })
{
	Driver* driver = select_driver(options)!;
	Audio* self = alloc::new(allocator, Audio);
	self.allocator = allocator;
	self.driver = driver;
	self.driver_state = driver.create(allocator, options, &self.capabilities)!;
	if (catch err = self.hub.start(allocator, "audio", driver.info.name, driver.run, self.driver_state))
	{
		driver.destroy(allocator, self.driver_state);
		alloc::free(allocator, self);
		return err~;
	}
	return self;
}

<* Stop the backend, release everything. Pending commands finish as CANCELLED. *>
fn void Audio.close(&self)
{
	self.hub.stop();
	self.driver.destroy(self.allocator, self.driver_state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend in use, for diagnostics ("pulse", "coreaudio", "wasapi"). *>
fn String Audio.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Audio.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "No state has been published yet"
*>
fn Snapshot{State}*? Audio.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`, then pass
 the previous snapshot's `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn Snapshot{State}*? Audio.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later state. Quick and non-blocking only. *>
fn WatchId{State} Audio.watch(&self, Listener{State} listener, void* context) => self.hub.state.watch(listener, context);

<* Remove a listener; when this returns it is not running. Not from inside a listener. *>
fn void Audio.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<* Subscribe to transient events (devices, streams, cards, defaults, microphone). *>
fn Reader{Event}*? Audio.subscribe(&self) => self.hub.events.subscribe();

<* Ask the backend to re-read the server now. *>
fn Pending*? Audio.refresh(&self) => self.submit(REFRESH, EVENTS, OUTPUT, "", "", { }, false);

<* Set the channel volumes of a device. Values above 1.0 need `DEVICE_BOOST`. *>
fn Pending*? Audio.set_device_volume(&self, Flow flow, String id, Gain[] gains)
{
	return self.submit(SET_DEVICE_VOLUME, DEVICE_VOLUME, flow, id, "", gains, false);
}

<* Mute or unmute a device. *>
fn Pending*? Audio.set_device_mute(&self, Flow flow, String id, bool muted)
{
	return self.submit(SET_DEVICE_MUTE, DEVICE_MUTE, flow, id, "", { }, muted);
}

<* Make a device the default for its flow. *>
fn Pending*? Audio.set_default(&self, Flow flow, String id)
{
	return self.submit(SET_DEFAULT, DEFAULT_SET, flow, id, "", { }, false);
}

<* Set the channel volumes of a playback or record stream. *>
fn Pending*? Audio.set_stream_volume(&self, String stream_id, Flow flow, Gain[] gains)
{
	return self.submit(SET_STREAM_VOLUME, STREAM_VOLUME, flow, stream_id, "", gains, false);
}

<* Mute or unmute a stream. *>
fn Pending*? Audio.set_stream_mute(&self, String stream_id, Flow flow, bool muted)
{
	return self.submit(SET_STREAM_MUTE, STREAM_MUTE, flow, stream_id, "", { }, muted);
}

<* Move a playback stream to another output device. `flow` is the stream's flow. *>
fn Pending*? Audio.move_stream(&self, String stream_id, Flow flow, String device_id)
{
	return self.submit(MOVE_STREAM, STREAM_MOVE, flow, stream_id, device_id, { }, false);
}

<* Choose a device's active port. *>
fn Pending*? Audio.set_port(&self, Flow flow, String device_id, String port_id)
{
	return self.submit(SET_PORT, PORT_SET, flow, device_id, port_id, { }, false);
}

<* Choose a card's profile. *>
fn Pending*? Audio.set_card_profile(&self, String card_id, String profile_id)
{
	return self.submit(SET_CARD_PROFILE, CARD_PROFILE_SET, OUTPUT, card_id, profile_id, { }, false);
}

// Copy the arguments into a new operation and queue it. Refused when the
// capability is absent: the caller learns why before anything is sent. A
// refresh names `EVENTS` only to satisfy the signature; it is never refused.
fn Pending*? Audio.submit(&self, CommandKind kind, Cap cap, Flow flow, String target, String choice, Gain[] gains, bool flag)
{
	if (kind != REFRESH)
	{
		Availability need = self.capabilities.values[cap.ordinal];
		if (!need.ok()) return need.refusal()~;
	}
	Pending* done = operation::begin{bool}(self.allocator);
	// An empty slice is not cloned: a zero-length copy from a null source asserts.
	Gain[] copied = gains.len > 0 ? alloc::clone_slice(done.allocator(), gains) : { };
	Command command = {
		.kind = kind,
		.flow = flow,
		.target = target.copy(done.allocator()),
		.choice = choice.copy(done.allocator()),
		.gains = copied,
		.flag = flag,
		.done = done.retain(),
	};
	if (catch err = self.hub.post(command))
	{
		done.release();
		done.release();
		return err~;
	}
	return done;
}
