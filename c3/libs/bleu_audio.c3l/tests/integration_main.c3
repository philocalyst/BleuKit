// Live integration test: the audio service against a PulseAudio native-protocol
// server. Run by run.sh, which sets BLEU_AUDIO_SOCKET (the server socket),
// BLEU_AUDIO_COOKIE (its cookie file) and BLEU_AUDIO_MODE: "mock" for
// pulse_mock.py (exact expectations, control socket for device changes) or
// "real" for a PulseAudio daemon (checks that hold for any server). Each check
// prints PASS or FAIL; the exit status is the number of failures.
module bleu::audio::integration_test;
import bleu::audio, bleu::availability, bleu::error, bleu::observe, bleu::stream, bleu::operation, bleu::unit, bleu::rt::unix;
import std::io, std::os::env, std::time, std::math;

<* Failed checks so far. *>
int failures = 0;

<* The server socket, for the control socket of the mock. *>
String socket_path = "";

<* What a predicate looks for in one state. *>
alias Predicate = fn bool(State* state);

fn void check(bool ok, String what)
{
	if (ok)
	{
		io::printfn("PASS %s", what);
		return;
	}
	io::printfn("FAIL %s", what);
	failures++;
}

fn bool near(float a, float b) => math::abs(a - b) < 0.001f;

<* Whether a channel volume is `b`; Gain is a distinct type, so it is compared as float. *>
fn bool near_gain(Gain a, float b) => near((float)a, b);

// Read states newer than the last one seen until `p` holds, for up to 10 seconds.
fn bool await(Audio* audio, Predicate p)
{
	ulong seen = 0;
	for (int i = 0; i < 20; i++)
	{
		if (try snapshot = audio.wait_after(seen, time::ms(500)))
		{
			defer snapshot.release();
			seen = snapshot.generation;
			if (p(&snapshot.value)) return true;
		}
	}
	return false;
}

// Wait until an event of `kind` naming `id` arrives, for up to 10 seconds.
fn bool saw_event(Reader{Event}* reader, EventKind kind, String id)
{
	for (int i = 0; i < 20; i++)
	{
		if (try packet = reader.next(time::ms(500)))
		{
			defer packet.release();
			if (packet.value.kind == kind && packet.value.id == id) return true;
		}
	}
	return false;
}

// Whether a command was accepted (a non-null operation) and then completed successfully.
fn bool completes(Pending* op)
{
	if (!op) return false;
	defer op.release();
	if (catch op.wait(time::ms(5000))) return false;
	return true;
}

// Send one line to the mock's control socket.
fn void control(String line)
{
	String path    = string::tformat("%s.ctl", socket_path);
	UnixSocket ctl = unix::connect(path, SocketKind.STREAM)!!;
	defer (void)ctl.close();
	ctl.send_all((char[])line)!!;
}

fn bool speakers(State* s) => s.outputs.len == 1 && s.outputs[0].form_factor == FormFactor.SPEAKERS;
fn bool half_volume(
	State* s
) => s.outputs.len == 1 && near_gain(s.outputs[0].volume[0], 0.5f) && near_gain(s.outputs[0].volume[1], 0.5f);
fn bool boosted(State* s) => s.outputs.len == 1 && near_gain(s.outputs[0].volume[0], 1.2f);
fn bool muted(State* s) => s.outputs.len == 1 && s.outputs[0].muted;
fn bool second_listed(State* s) => s.outputs.len == 2;
fn bool second_gone(State* s) => s.outputs.len == 1;
fn bool second_is_default(State* s) => s.default_output == "bleu.second";
fn bool stream_on_second(State* s) => s.streams.len > 0 && s.streams[0].device_id == "bleu.second";
fn bool stream_quarter(State* s) => s.streams.len > 0 && near_gain(s.streams[0].volume[0], 0.25f);
fn bool card_off(State* s) => s.cards.len == 1 && s.cards[0].active_profile == "off";
fn bool no_outputs(State* s) => s.outputs.len == 0;
fn bool has_outputs(State* s) => s.outputs.len > 0;

// The mock's state is fixed, so its expectations are exact.
fn void mock_state(Audio* audio)
{
	if (try snapshot = audio.latest())
	{
		defer snapshot.release();
		State* s = &snapshot.value;
		check(s.outputs.len == 1, "one output device (the monitor source is not listed)");
		check(s.outputs.len == 1 && s.outputs[0].id == "alsa_output.test", "output id is the sink name");
		check(s.outputs.len == 1 && s.outputs[0].name == "Test Sink", "output name is the description");
		check(
			s.outputs.len == 1 && s.outputs[0].form_factor == FormFactor.SPEAKERS && s.outputs[0].bus == Bus.PCI,
			"speaker on Bus.PCI"
		);
		check(
			s.outputs.len == 1 && s.outputs[0].is_default && s.default_output == "alsa_output.test",
			"output is the default"
		);
		check(
			s.outputs.len == 1 && s.outputs[0].volume.len == 2 && near_gain(s.outputs[0].volume[0], 1.0f),
			"two channels at 100 %"
		);
		check(s.outputs.len == 1 && near(s.outputs[0].level.percent(), 100.0f), "level view is 100 %");
		check(
			s.outputs.len == 1 && s.outputs[0].balance.has_value && near(s.outputs[0].balance.value, 0.0f),
			"balance is centred"
		);
		check(
			s.outputs.len == 1 && s.outputs[0].ports.len == 1 && s.outputs[0].ports[0].active,
			"the active port is listed"
		);
		check(s.outputs.len == 1 && s.outputs[0].volume_is_hardware, "the sink has a hardware volume control");
		check(
			s.inputs.len == 1 && s.inputs[0].id == "alsa_input.test"
				&& s.inputs[0].form_factor == FormFactor.MICROPHONE,
			"input is the microphone"
		);
		check(s.inputs.len == 1 && s.inputs[0].bus == Bus.USB, "microphone on Bus.USB");
		check(s.streams.len == 2, "two streams: playback and record");
		check(
			s.streams.len == 2 && s.streams[0].flow == Flow.OUTPUT && s.streams[0].app_name == "Music Player",
			"playback stream names its app"
		);
		check(
			s.streams.len == 2 && s.streams[0].pid == 4321 && s.streams[0].binary == "musicplayer",
			"playback stream pid and binary"
		);
		check(s.streams.len == 2 && s.streams[0].device_id == "alsa_output.test", "playback stream is on the sink");
		check(
			s.streams.len == 2 && s.streams[1].flow == Flow.INPUT && s.streams[1].device_id == "alsa_input.test",
			"record stream is on the mic"
		);
		check(s.mic_in_use, "microphone in use: an unmuted record stream exists");
		check(
			s.cards.len == 1 && s.cards[0].profiles.len == 2 && s.cards[0].active_profile == "a2dp-sink",
			"card profiles and active profile"
		);
	}
	else
	{
		check(false, "a state is published");
	}
	check(audio.capability(Cap.PEAK_METER)
		.reason == availability::Reason.UNSUPPORTED_BACKEND, "peak meter is unsupported in v1");
	check(audio.capability(Cap.DEVICE_VOLUME).ok(), "device volume is available");
}

// Commands against the mock, each checked in the state it should change.
fn void mock_commands(Audio* audio, Reader{Event}* reader)
{
	Gain[2] half = { (Gain)0.5f, (Gain)0.5f };
	check(
		completes(audio.set_device_volume(Flow.OUTPUT, "alsa_output.test", half[..]) ?? null),
		"set_device_volume accepted"
	);
	check(await(audio, &half_volume), "volume 50 % is published");
	check(
		saw_event(reader, EventKind.DEVICE_CHANGED, "alsa_output.test"),
		"EventKind.DEVICE_CHANGED event for the volume"
	);

	check(completes(audio.set_device_mute(Flow.OUTPUT, "alsa_output.test", true) ?? null), "set_device_mute accepted");
	check(await(audio, &muted), "mute is published");

	Gain[2] boost = { (Gain)1.2f, (Gain)1.2f };
	check(
		completes(audio.set_device_volume(Flow.OUTPUT, "alsa_output.test", boost[..]) ?? null),
		"boost above 100 % accepted"
	);
	check(await(audio, &boosted), "120 % is published (above nominal)");

	Gain[] none  = { };
	bool refused = false;
	if (try op = audio.set_device_volume(Flow.OUTPUT, "alsa_output.test", none))
	{
		defer op.release();
		if (catch err = op.wait(time::ms(5000))) refused = err == error::INVALID_ARGUMENT;
	}
	check(refused, "an empty volume is refused with INVALID_ARGUMENT");

	Gain[2] quarter = { (Gain)0.25f, (Gain)0.25f };
	check(completes(audio.set_stream_volume("20", Flow.OUTPUT, quarter[..]) ?? null), "set_stream_volume accepted");
	check(await(audio, &stream_quarter), "stream volume 25 % is published");
	check(completes(audio.set_stream_mute("20", Flow.OUTPUT, true) ?? null), "set_stream_mute accepted");

	control("add-sink bleu.second");
	check(saw_event(reader, EventKind.DEVICE_ADDED, "bleu.second"), "EventKind.DEVICE_ADDED event for a new sink");
	check(await(audio, &second_listed), "the new sink is listed");

	check(completes(audio.set_default(Flow.OUTPUT, "bleu.second") ?? null), "set_default accepted");
	check(await(audio, &second_is_default), "the new default is published");
	check(
		saw_event(reader, EventKind.DEFAULT_CHANGED, "bleu.second"),
		"EventKind.DEFAULT_CHANGED event names the new default"
	);

	check(completes(audio.move_stream("20", Flow.OUTPUT, "bleu.second") ?? null), "move_stream accepted");
	check(await(audio, &stream_on_second), "the stream moved to the new sink");

	check(
		completes(audio.set_port(Flow.OUTPUT, "alsa_output.test", "analog-output-headphones") ?? null),
		"set_port accepted"
	);
	check(completes(audio.set_card_profile("alsa_card.test", "off") ?? null), "set_card_profile accepted");
	check(await(audio, &card_off), "the card profile is published");

	control("remove-sink bleu.second");
	check(saw_event(reader, EventKind.DEVICE_REMOVED, "bleu.second"), "EventKind.DEVICE_REMOVED event for the sink");
	check(await(audio, &second_gone), "the removed sink is gone");
}

// The server going away: the state empties and commands fail rather than hang.
fn void mock_disconnect(Audio* audio)
{
	control("exit");
	check(await(audio, &no_outputs), "server exit publishes an empty state");
	bool failed = false;
	if (try op = audio.set_device_mute(Flow.OUTPUT, "alsa_output.test", false))
	{
		defer op.release();
		if (catch err = op.wait(time::ms(5000))) failed = err == error::UNAVAILABLE || err == error::DISCONNECTED;
	}
	check(failed, "a command during the outage fails with UNAVAILABLE or DISCONNECTED");
}

// Against a real server: the checks that hold for any server state. The target
// output's volume and mute are changed and then restored. The target is the
// default output, or the first output when the server names no default
// (pipewire-pulse 1.0.5 reports none through the protocol).
String target_id = "";

fn bool target_half(State* s)
{
	foreach (&d : s.outputs)
	{
		if (d.id == target_id) return near_gain(d.volume[0], 0.5f);
	}
	return false;
}

fn bool target_muted(State* s)
{
	foreach (&d : s.outputs)
	{
		if (d.id == target_id) return d.muted;
	}
	return false;
}

fn bool target_unmuted(State* s)
{
	foreach (&d : s.outputs)
	{
		if (d.id == target_id) return !d.muted;
	}
	return false;
}

fn void real_server(Audio* audio)
{
	check(await(audio, &has_outputs), "a real server publishes at least one output");
	Gain[] saved = { };
	if (try snapshot = audio.latest())
	{
		defer snapshot.release();
		State* s    = &snapshot.value;
		bool listed = s.default_output.len == 0;
		foreach (&d : s.outputs)
		{
			if (d.id == s.default_output) listed = true;
		}
		check(listed, "the default output, when named, is one of the listed outputs");
		target_id = s.default_output.len > 0 ? s.default_output.copy(mem) : s.outputs[0].id.copy(mem);
		foreach (&d : s.outputs)
		{
			if (d.id == target_id) saved = alloc::clone_slice(mem, d.volume);
		}
	}
	check(saved.len > 0, "the target output has a volume");
	Gain[2] half = { (Gain)0.5f, (Gain)0.5f };
	check(
		completes(audio.set_device_volume(Flow.OUTPUT, target_id, half[..]) ?? null),
		"set the target output to 50 %"
	);
	check(await(audio, &target_half), "50 % is published for the target output");
	check(completes(audio.set_device_mute(Flow.OUTPUT, target_id, true) ?? null), "mute the target output");
	check(await(audio, &target_muted), "mute is published");
	check(completes(audio.set_device_mute(Flow.OUTPUT, target_id, false) ?? null), "unmute the target output");
	check(await(audio, &target_unmuted), "unmute is published");
	check(
		completes(audio.set_device_volume(Flow.OUTPUT, target_id, saved) ?? null),
		"restore the target output volume"
	);
}

fn int main()
{
	socket_path = (String)(env::get_var(mem, "BLEU_AUDIO_SOCKET") ?? "");
	String cookie   = (String)(env::get_var(mem, "BLEU_AUDIO_COOKIE") ?? "");
	bool mock       = (env::get_var(mem, "BLEU_AUDIO_MODE") ?? "mock") == "mock";
	Options options = { .backend = Backend.PULSE, .server = socket_path, .cookie_file = cookie };
	Audio*? opened  = audio::open(mem, options);
	if (catch err = opened)
	{
		check(false, "open the service on the server socket");
		return failures;
	}
	Audio* service = opened;
	defer service.close();
	check(service.backend_name() == "pulse", "the pulse backend is chosen");
	Reader{Event}* reader = service.subscribe()!!;
	defer reader.release();
	if (mock)
	{
		check(await(service, &speakers), "the mock's sink is published");
		mock_state(service);
		mock_commands(service, reader);
		mock_disconnect(service);
	}
	else
	{
		real_server(service);
	}
	io::printfn("%d failure(s)", failures);
	return failures;
}