<*
 The Linux backend: gamma ramps through `zwlr_gamma_control_manager_v1` on a wlroots-style
 Wayland compositor: the wlroots family, and any compositor that implements wlr-gamma-control.

 The protocol (wlr-gamma-control-unstable-v1.xml from wlr-protocols, read for the requests and events
 used; `bleu_wl`'s generated copy matches): `get_gamma_control`
 returns an object that sends `gamma_size(size)` at once and then accepts `set_gamma(fd)`. The fd
 holds three successive ramps of `size` 16-bit words; the compositor applies them. `failed` means
 the control is no longer valid: another client holds the output's exclusive control, the output has
 no gamma table, or setting it failed. The client then destroys the object. `destroy` restores the
 output's own table, and the compositor restores it too when the client's connection closes.

 Gamma control is exclusive per output, so this backend holds an output's control only while it
 has a ramp on it. At open it takes and releases each output's control once, to learn the size and
 whether another client holds it. A neutral ramp releases the control again.

 The ramp descriptor is a memfd (`memfd_create(2)`): anonymous memory the compositor may read or
 map. It is written with `pwrite(2)` at offset 0, so the descriptor's file offset stays at 0 for a
 reader that reads rather than maps.

 COMPILED ONLY for the real compositor path: the protocol exchange is run against the in-process
 mock compositor (linux_wlr_test.c3). No wlroots compositor was run; see README.md.
*>
module bleu::color::linux_wlr @feat(LINUX);
import bleu::availability, bleu::color, bleu::color::engine, bleu::color::ramp, bleu::error, bleu::rt, bleu::rt::poller, bleu::rt::unix, bleu::rt::worker, bleu::service, bleu::wl, bleu::wl::display, bleu::wl::proto::wayland, bleu::wl::proto::wlr_gamma_control, bleu::unit, libc, std::time, std::core::mem;

<* The name of a ramp's memfd. It shows in /proc only while the descriptor is open. *>
const String RAMP_NAME = "bleu-color-ramp";

<* `MFD_CLOEXEC` from linux/memfd.h: the descriptor is closed across exec. *>
const uint MFD_CLOEXEC = 0x0001;

<* Bytes in one ramp entry: the protocol's 16-bit unsigned words. *>
const usz WORD_BYTES = ushort::size;

<* The poller tag of the compositor connection. The wake-up has its own tag. *>
const usz CONNECTION_TAG = 1;

<* Sources the poller holds: the connection only. *>
const usz POLLER_CAPACITY = 2;

<* Longest output name accepted from the compositor; a longer one is ignored. *>
const usz MAX_NAME = 256;

// Source: memfd_create(2), https://man7.org/linux/man-pages/man2/memfd_create.2.html: int memfd_create(const char *name, unsigned int flags).
extern fn int memfd_create(char* name, uint flags) @cname("memfd_create");

// Source: POSIX.1-2008 pwrite(2): ssize_t pwrite(int fd, const void *buf, size_t count, off_t offset).
extern fn sz pwrite(int fd, void* buffer, usz count, long offset) @cname("pwrite");

<* One wl_output and its gamma control, as the backend tracks them. Their addresses are stable. *>
struct WlrDisplay
{
	Allocator allocator;
	uint global_name;
	wayland::WlOutput* output;
	String name;
	wlr_gamma_control::ZwlrGammaControlV1* control;
	uint size;
	bool failed;
	ushort[] words;
}

<* The backend's state. The connection and the displays exist only while `run` is active. *>
struct Wlr
{
	Allocator allocator;
	Duration tick;
	ConnectFn connect;
	void* connect_context;
	wl::Client* client;
	wlr_gamma_control::ZwlrGammaControlManagerV1* manager;
	WlrDisplay[] displays;
}

const Driver DRIVER = {
	.info = { "wlr-gamma", "wlr-gamma-control on a Wayland compositor (zwlr_gamma_control_manager_v1)", 20 },
	.id = Backend.WLR_GAMMA,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

<*
 Whether a compositor with gamma control can be reached: connect, read the registry, disconnect.
 Takes no gamma control.

 A test seam (`Options.connect`) is taken as the caller's word that the compositor is there, so the
 probe does not use up the seam's one connection.
*>
fn bool probe(Options* options)
{
	if (options.connect != null) return true;
	wl::Client client;
	if (catch client.connect_env(mem)) return false;
	defer client.close();
	if (catch client.roundtrip()) return false;
	foreach (global : client.globals_view())
	{
		if (global.interface_name == wlr_gamma_control::ZWLR_GAMMA_CONTROL_MANAGER_V1.name) return true;
	}
	return false;
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.set(
		Cap.GAMMA_RAMP,
		{
			.reason = availability::Reason.DEGRADED,
			.note = "gamma control is per output and exclusive: see each output's control",
		}
	);
	return alloc::new(
		allocator,
		Wlr,
		{
			.allocator = allocator,
			.tick = options.tick,
			.connect = options.connect,
			.connect_context = options.connect_context,
		}
	);
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, (Wlr*)state);
}

<*
 Connect as the test seam says, or as the environment says. On failure the client is not in place
 and the descriptor is closed.
*>
fn void? connect(Wlr* wlr, wl::Client* client)
{
	if (wlr.connect == null) return client.connect_env(wlr.allocator);
	rt::Native fd = wlr.connect(wlr.connect_context)!;
	if (catch err = client.init(wlr.allocator, fd))
	{
		display::native_close(fd);
		return err~;
	}
}

<*
 The worker: connect, find the outputs, learn their gamma sizes, then serve commands and the
 compositor's events until stopped or until the connection fails. A compositor that cannot be used
 leaves the service without a state, and `latest()` keeps saying UNAVAILABLE.
*>
fn void run(void* state, ColorHub* hub, Host{Command}* host)
{
	Wlr* wlr = (Wlr*)state;
	defer wlr.free_displays();
	wl::Client client;
	if (catch connect(wlr, &client)) return;
	defer client.close();
	wlr.client = &client;
	if (catch setup(wlr)) return;
	Platform platform = { .context = wlr, .write = &write_ramp, .release = &release_ramp };
	Engine engine;
	// The outputs are temporary: the engine copies the strings it keeps.
	@pool()
	{
		engine.init(wlr.allocator, hub, &platform, outputs_of(wlr));
	};
	defer engine.free();
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), POLLER_CAPACITY)) return;
	defer poller.free();
	if (catch poller.add(
		{
			.handle = client.native(),
			.interest = { .readable = true, .hangup = true, .failed = true },
			.tag = CONNECTION_TAG
		}
	)) return;
	engine.publish();
	bool connected = true;
	bool writable  = false;
	while (!host.stopping() && connected)
	{
		// Sleeps until the next tick, a command, or the compositor has something to say.
		Ready[]? ready = poller.wait(wlr.tick);
		if (catch err = ready)
		{
			// TIMEOUT is the normal tick; any other failure of the wait ends the loop.
			if (err != TIMEOUT) connected = false;
		}
		else
		{
			foreach (event : ready)
			{
				if (event.tag != CONNECTION_TAG) continue;
				if (catch client.dispatch())
				{
					connected = false;
					break;
				}
			}
		}
		// Refusals first: a command drained now must see the displays the compositor took back.
		wlr.release_lost(&engine);
		engine.drain(host);
		if (catch client.flush()) connected = false;
		sync_writable(&poller, &client, &writable, &connected);
		engine.tick();
		engine.publish();
	}
	if (!connected) wlr.disconnected(&engine);
	engine.publish();
	engine.cancel_queued(host);
	wlr.release_all();
	if (catch client.flush())
	{
	}
}

<*
 Bind the outputs and the manager, learn each output's name, and measure every output's gamma
 size. Leaves `wlr.displays` and `wlr.manager` set.
*>
fn void? setup(Wlr* wlr)
{
	wl::Client* client = wlr.client;
	client.roundtrip()!;
	usz outputs      = 0;
	Global[] globals = client.globals_view();
	foreach (global : globals)
	{
		if (global.interface_name == wayland::WL_OUTPUT.name) outputs++;
	}
	wlr.displays = alloc::new_array(wlr.allocator, WlrDisplay, (sz)outputs);
	usz next = 0;
	foreach (global : globals)
	{
		if (global.interface_name == wayland::WL_OUTPUT.name)
		{
			WlrDisplay* slot = &wlr.displays[next++];
			slot.allocator = wlr.allocator;
			slot.global_name = global.name;
			slot.output = (wayland::WlOutput*)client.bind(global, wayland::WL_OUTPUT)!;
			slot.output.set_listener(&OUTPUT_LISTENER, slot);
		}
		else if (global.interface_name == wlr_gamma_control::ZWLR_GAMMA_CONTROL_MANAGER_V1.name)
		{
			wlr.manager = (wlr_gamma_control::ZwlrGammaControlManagerV1*)client.bind(
				global,
				wlr_gamma_control::ZWLR_GAMMA_CONTROL_MANAGER_V1
			)!;
		}
	}
	if (wlr.manager == null)
	{
		return error::raise(
			error::UNAVAILABLE,
			error::Domain.INTERNAL,
			0,
			"the compositor has no gamma control manager"
		)~;
	}
	// The names arrive with the wl_output events, which come before this sync's done.
	client.roundtrip()!;
	wlr.measure()!;
}

<*
 Ask each output for its gamma control once, learn its size and whether it refuses, and destroy it.
 Destroying an untouched control changes nothing on the screen.
*>
fn void? Wlr.measure(&self)
{
	foreach (&slot : self.displays)
	{
		slot.control = self.manager.get_gamma_control(slot.output)!;
		slot.control.set_listener(&GAMMA_LISTENER, slot);
	}
	self.client.roundtrip()!;
	foreach (&slot : self.displays)
	{
		if (slot.control == null) continue;
		if (catch slot.control.destroy())
		{
		}
		slot.control = null;
		if (slot.size >= 2) slot.words = alloc::new_array(self.allocator, ushort, 3 * (sz)slot.size);
	}
}

<* The engine's outputs, from what `setup` learned. The engine copies the strings, so they are temporary. *>
fn Output[] outputs_of(Wlr* wlr)
{
	Output[] outputs = alloc::new_array(tmem, Output, wlr.displays.len);
	foreach (i, slot : wlr.displays)
	{
		String id = slot.name.len > 0 ? slot.name : string::tformat("wl_output-%d", slot.global_name);
		Control control = {
			.gamma_supported = slot.size >= 2,
			.availability = availability::YES,
			.size = slot.size,
			.brightness = (Level)1.0f,
			.refused = slot.failed,
		};
		if (slot.size < 2)
		{
			control.availability = availability::no(
				availability::Reason.UNSUPPORTED_BACKEND,
				"the output sent no gamma table: it has none, or the compositor refused gamma control"
			);
		}
		outputs[i] = { .id = id, .name = slot.name, .control = control };
	}
	return outputs;
}

<* Output events: the name (protocol version 4 and later) is kept. The rest is not used. *>
const wayland::WlOutputListener OUTPUT_LISTENER = { .name = &on_output_name };

fn void on_output_name(void* context, wayland::WlOutput* target, String name)
{
	WlrDisplay* slot = (WlrDisplay*)context;
	if (name.len > MAX_NAME) return;
	if (slot.name.len > 0) alloc::free(slot.allocator, slot.name.ptr);
	slot.name = name.copy(slot.allocator);
}

<* Gamma control events: the size, and the refusal that ends a control. *>
const wlr_gamma_control::ZwlrGammaControlV1Listener GAMMA_LISTENER = {
	.gamma_size = &on_gamma_size,
	.failed = &on_gamma_failed,
};

fn void on_gamma_size(void* context, wlr_gamma_control::ZwlrGammaControlV1* target, uint size)
{
	WlrDisplay* slot = (WlrDisplay*)context;
	slot.size = size;
}

fn void on_gamma_failed(void* context, wlr_gamma_control::ZwlrGammaControlV1* target)
{
	WlrDisplay* slot = (WlrDisplay*)context;
	slot.failed = true;
}

<*
 Write `ramp` to display `index`. Takes the display's gamma control if this backend does not hold
 it. A control refused at that point is destroyed, as the protocol asks, and reported as BUSY.
*>
fn void? Wlr.write(&self, usz index, float[] ramp)
{
	WlrDisplay* slot = &self.displays[index];
	if (slot.control == null)
	{
		slot.control = self.manager.get_gamma_control(slot.output)!;
		slot.control.set_listener(&GAMMA_LISTENER, slot);
		slot.failed = false;
		self.client.roundtrip()!;
		if (slot.failed)
		{
			if (catch slot.control.destroy())
			{
			}
			slot.control = null;
			return error::raise(
				error::BUSY,
				error::Domain.COMPOSITOR,
				0,
				"%s: the compositor refused gamma control",
				slot.name
			)~;
		}
	}
	if (slot.size < 2 || 3 * (usz)slot.size != (usz)ramp.len)
	{
		return error::raise(
			error::UNSUPPORTED,
			error::Domain.INTERNAL,
			0,
			"%s: the ramp does not match the output",
			slot.name
		)~;
	}
	ramp::encode_u16(ramp, slot.words)!;
	rt::Native fd = ramp_descriptor(slot.words)!;
	defer display::native_close(fd);
	slot.control.set_gamma(fd)!;
	self.client.flush()!;
}

<* Engine callback: write display `index`. See `Wlr.write`. *>
fn void? write_ramp(void* context, usz index, float[] ramp)
{
	Wlr* wlr = (Wlr*)context;
	return wlr.write(index, ramp);
}

<*
 Engine callback: give display `index` back its own table. Releases its control, so the compositor
 restores the output's table.
*>
fn void release_ramp(void* context, usz index)
{
	Wlr* wlr = (Wlr*)context;
	wlr.release(index);
}

// Destroy display `index`'s gamma control if it holds one. The compositor restores the table.
fn void Wlr.release(&self, usz index)
{
	WlrDisplay* slot = &self.displays[index];
	if (slot.control == null) return;
	if (catch slot.control.destroy())
	{
	}
	slot.control = null;
}

// Free the displays, their names and their ramp buffers. The connection's proxies are the client's.
fn void Wlr.free_displays(&self)
{
	foreach (&slot : self.displays)
	{
		if (slot.name.len > 0) alloc::free(self.allocator, slot.name.ptr);
		if (slot.words.len > 0) alloc::free(self.allocator, slot.words.ptr);
	}
	if (self.displays.len > 0) alloc::free(self.allocator, self.displays.ptr);
	self.displays = { };
}

// Destroy every control this backend holds. Used at shutdown.
fn void Wlr.release_all(&self)
{
	for (usz i = 0; i < self.displays.len; i++) self.release(i);
}

<*
 A display whose control the compositor took (`failed`) gives it up: the control is destroyed as
 the protocol asks, and the engine reports the display as lost.
*>
fn void Wlr.release_lost(&self, Engine* engine)
{
	for (usz i = 0; i < self.displays.len; i++)
	{
		WlrDisplay* slot = &self.displays[i];
		if (!slot.failed || slot.control == null) continue;
		self.release(i);
		slot.failed = false;
		engine.lost(i);
	}
}

<*
 Wait for the compositor's write readiness exactly while the outbox holds bytes the socket did not
 take: a partly flushed request then goes out at once, not at the next event or tick.
*>
fn void sync_writable(Poller* poller, wl::Client* client, bool* writable, bool* connected) @private
{
	bool wanted = client.wants_write();
	if (wanted == *writable) return;
	if (catch poller.remove(CONNECTION_TAG))
	{
		*connected = false;
		return;
	}
	if (catch poller.add(
		{
			.handle = client.native(),
			.interest = { .readable = true, .writable = wanted, .hangup = true, .failed = true },
			.tag = CONNECTION_TAG
		}
	))
	{
		*connected = false;
		return;
	}
	*writable = wanted;
}

<*
 The connection failed: no display can be written any more. Every display reports that the
 compositor stopped, and holds no control.
*>
fn void Wlr.disconnected(&self, Engine* engine)
{
	for (usz i = 0; i < self.displays.len; i++)
	{
		self.displays[i].control = null;
		Control* control = &engine.displays[i].output.control;
		control.gamma_supported = false;
		control.availability = availability::no(
			availability::Reason.BACKEND_STOPPED,
			"the compositor closed the connection"
		);
		control.active = false;
	}
}

<*
 A descriptor holding `words` as bytes, ready for `set_gamma`. The caller closes it.

 @return? error::BACKEND_FAILURE : "memfd_create or pwrite failed (errno in the detail)"
*>
fn rt::Native? ramp_descriptor(ushort[] words)
{
	rt::Native fd = memfd_create(RAMP_NAME.ptr, MFD_CLOEXEC);
	if (fd < 0) return unix::errno_fault("memfd_create", libc::errno())~;
	if (catch err = write_words(fd, words))
	{
		display::native_close(fd);
		return err~;
	}
	return fd;
}

// Write the words at offset 0 of `fd`, all of them or an error.
fn void? write_words(rt::Native fd, ushort[] words)
{
	usz bytes  = words.len * WORD_BYTES;
	sz written = pwrite(fd, words.ptr, bytes, 0);
	if (written < 0) return unix::errno_fault("pwrite", libc::errno())~;
	if ((usz)written != bytes)
	{
		return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.INTERNAL,
			0,
			"pwrite wrote %d of %d bytes",
			written,
			bytes
		)~;
	}
}