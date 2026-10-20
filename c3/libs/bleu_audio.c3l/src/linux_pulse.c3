<*
 The PulseAudio native-protocol backend (Linux): PulseAudio itself, or
 PipeWire's pulse server, which speaks the same protocol (research 2.1.7).

 The worker connects, publishes, and then waits on the socket and on the
 command mailbox. A subscription event triggers a full refresh, coalesced:
 many events in one wake-up cost one refresh. When the server goes away the
 worker publishes an empty state and retries every RECONNECT_DELAY; commands
 queued meanwhile fail with UNAVAILABLE.
*>
module bleu::audio::linux_pulse @feat(LINUX);
import std::time, std::io::path, bleu::availability, bleu::audio, bleu::error, bleu::rt::poller, bleu::rt::worker, bleu::operation;

const Duration RECONNECT_DELAY = (Duration)1_000_000; // 1 s between attempts to reach the server
const usz COMMAND_BATCH        = 16;

<*
 What the backend remembers: where the server socket and its cookie are. Each
 string is owned by the backend (copied into the open's allocator) when it is
 not empty; an empty cookie path is the literal "" and owns nothing.
*>
struct PulseBackend
{
	String socket_path;
	String cookie_path;
}

const Driver DRIVER = {
	.info = { "pulse", "PulseAudio native protocol (PulseAudio or PipeWire pulse server)", 100 },
	.id = PULSE,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

fn bool probe(Options* options) => socket_exists(options);

<*
 Find the socket and the cookie. An explicit cookie file, or PULSE_COOKIE, that
 does not exist is an error here: the worker would otherwise retry forever.

 @return? error::UNAVAILABLE : "no socket path can be found"
 @return? NOT_FOUND : "the cookie file named by the options or PULSE_COOKIE does not exist"
*>
fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.values[Cap.PEAK_METER.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"no level meters in this version"
	);
	capabilities.values[Cap.MIC_IN_USE.ordinal] = {
		availability::Reason.DEGRADED,
		"heuristic: an unmuted, uncorked recording stream"
	};
	capabilities.values[Cap.DEVICE_BOOST.ordinal] = { availability::Reason.AVAILABLE, "" };
	String socket = server_path(allocator, options.server)!;
	String cookie = cookie_path(allocator, options.cookie_file);
	if (cookie.len > 0 && !path::exists((Path)cookie))
	{
		free_owned(allocator, socket);
		free_owned(allocator, cookie);
		return error::raise(
			NOT_FOUND,
			error::Domain.INTERNAL,
			0,
			"cookie file %s does not exist",
			cookie
		)~;
	}
	return alloc::new(allocator, PulseBackend, { .socket_path = socket, .cookie_path = cookie });
}

fn void destroy(Allocator allocator, void* state)
{
	PulseBackend* backend = (PulseBackend*)state;
	free_owned(allocator, backend.socket_path);
	free_owned(allocator, backend.cookie_path);
	alloc::free(allocator, backend);
}

// Free a string that the backend copied; the empty literal is not heap memory and is skipped.
fn void free_owned(Allocator allocator, String text) @private
{
	if (text.len > 0) alloc::free(allocator, text.ptr);
}

// Connect with the cookie file's bytes; with no cookie file the cookie is zeros, which only anonymous servers accept.
fn Session*? connect(Allocator allocator, PulseBackend* backend, Host{Command}* host)
{
	char[pulse::COOKIE_LENGTH] cookie;
	@pool()
	{
		cookie_bytes(backend.cookie_path, &cookie)!;
	};
	return open_session(allocator, backend.socket_path, &cookie, host);
}

fn void run(void* state, AudioHub* hub, Host{Command}* host)
{
	PulseBackend* backend = (PulseBackend*)state;
	Poller delay;
	if (catch delay.init(mem, host.wakeup(), 1)) return;
	defer delay.free();
	while (!host.stopping())
	{
		Session*? opened = connect(mem, backend, host);
		if (catch err = opened)
		{
			audio::publish_empty(hub);
			wait_before_retry(host, &delay);
			continue;
		}
		Session* session = opened;
		serve(session, hub, host);
		session.close();
		audio::publish_empty(hub);
		wait_before_retry(host, &delay);
	}
}

// Sleep until the retry delay passes or a command arrives; commands fail meanwhile.
fn void wait_before_retry(Host{Command}* host, Poller* delay) @private
{
	if (catch delay.wait(RECONNECT_DELAY))
	{
		// TIMEOUT is the normal end of the delay.
	}
	Command[COMMAND_BATCH] buffer;
	usz count = host.mailbox().take_all(buffer[..]);
	for (usz i = 0; i < count; i++)
	{
		Pending* done = buffer[i].done;
		(void)done.fail(error::UNAVAILABLE);
		done.release();
	}
}

// Work with one connected session until it fails or the worker stops.
fn void serve(Session* session, AudioHub* hub, Host{Command}* host) @private
{
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 2)) return;
	defer poller.free();
	if (catch poller.add(
		{ .handle = session.socket.fd.raw(), .interest = { .readable = true }, .tag = SOCKET_TAG }
	)) return;
	if (catch session.refresh(hub)) return;
	if (refresh_until_quiet(session, hub)) return;
	Command[COMMAND_BATCH] buffer;
	while (!host.stopping())
	{
		bool broken = false;
		@pool()
		{
			if (try ready = poller.wait())
			{
				foreach (event : ready)
				{
					if (event.tag != SOCKET_TAG) continue;
					if (catch session.absorb()) broken = true;
				}
			}
			else
			{
				broken = true;
			}
			usz count = host.mailbox().take_all(buffer[..]);
			for (usz i = 0; i < count; i++)
			{
				Pending* done = buffer[i].done;
				if (catch err = session.execute(&buffer[i], hub))
				{
					(void)done.fail(err);
					broken = broken || breaks_session(err);
				}
				else
				{
					(void)done.succeed(true);
				}
				done.release();
			}
		};
		if (broken || refresh_until_quiet(session, hub)) return;
	}
}

<*
 Refresh while subscription events keep arriving. An event that arrived during a
 reply wait is consumed there and only flags `events_seen`; no socket readiness
 follows it, so the flag must be acted on here rather than at the next wait.

 @return "true when the session broke and must be closed"
*>
fn bool refresh_until_quiet(Session* session, AudioHub* hub) @private
{
	while (session.events_seen)
	{
		session.events_seen = false;
		if (catch session.refresh(hub)) return true;
	}
	return false;
}