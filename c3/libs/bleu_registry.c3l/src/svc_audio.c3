<* The `audio` entry of the registry: open adapter, commands and `Spec`. *>
module bleu::registry::svc_audio;
import std::time, bleu::audio, bleu::registry, bleu::registry::live, bleu::observe, bleu::error, bleu::unit, bleu::json, bleu::registry::tap;

<* The most channels a device may have; PulseAudio's PA_CHANNELS_MAX (32). *>
const usz CHANNEL_LIMIT = 32;

<* Open the audio service with its default backend. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	audio::Audio* service = audio::open(allocator)!;
	return (void*)service;
}

<*
 Fill `gains` with `level` for every channel of the device `id`. The channel count
 comes from the latest state, so a stereo device gets two gains.

 @return? NOT_FOUND : "No device of that flow has that id"
 @return? error::INVALID_ARGUMENT : "The device has no channels or more than CHANNEL_LIMIT"
*>
fn usz? fill_device_gains(audio::Audio* service, audio::Flow flow, String id, Level level, Gain[] gains) @private
{
	Snapshot{audio::State}* snapshot = service.latest()!;
	defer snapshot.release();
	audio::Device[] devices = flow == audio::Flow.INPUT ? snapshot.value.inputs : snapshot.value.outputs;
	foreach (&device : devices)
	{
		if (device.id != id) continue;
		usz channels = device.volume.len;
		if (channels == 0 || channels > gains.len)
		{
			return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "device %s has %d channels", id, channels)~;
		}
		for (usz i = 0; i < channels; i++)
		{
			gains[i] = unit::gain((float)level, 1.0f);
		}
		return channels;
	}
	return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no %s device %s", flow, id)~;
}

<*
 `audio.set_volume {flow, id, volume}`: set every channel of a device to `volume`
 (0 to 1). Each channel gets the same value; per-channel volumes are not yet a request.
*>
fn void? set_volume(registry::Request* request)
{
	audio::Audio* service = (audio::Audio*)request.handle;
	audio::Flow flow = registry::parse_enum{audio::Flow}(request.params.string("flow")!)!;
	String id = request.params.string("id")!;
	Level level = (Level)(float)request.params.number("volume")!;
	Gain[CHANNEL_LIMIT] gains;
	usz channels = fill_device_gains(service, flow, id, level, &gains)!;
	audio::Pending* operation = service.set_device_volume(flow, id, gains[0:channels])!;
	defer operation.release();
	registry::await{bool}(operation, request.timeout)!;
	return registry::write_ok(request.out);
}

<* `audio.set_mute {flow, id, muted}`: mute or unmute a device. *>
fn void? set_mute(registry::Request* request)
{
	audio::Audio* service = (audio::Audio*)request.handle;
	audio::Flow flow = registry::parse_enum{audio::Flow}(request.params.string("flow")!)!;
	String id = request.params.string("id")!;
	bool muted = request.params.boolean("muted")!;
	audio::Pending* operation = service.set_device_mute(flow, id, muted)!;
	defer operation.release();
	registry::await{bool}(operation, request.timeout)!;
	return registry::write_ok(request.out);
}

<* `audio.set_default {flow, id}`: make a device the default output or input. *>
fn void? set_default(registry::Request* request)
{
	audio::Audio* service = (audio::Audio*)request.handle;
	audio::Flow flow = registry::parse_enum{audio::Flow}(request.params.string("flow")!)!;
	String id = request.params.string("id")!;
	audio::Pending* operation = service.set_default(flow, id)!;
	defer operation.release();
	registry::await{bool}(operation, request.timeout)!;
	return registry::write_ok(request.out);
}

const registry::Command[3] COMMANDS = {
	{ .name = "audio.set_volume", .summary = "Set every channel of a device: {flow, id, volume}.", .run = &set_volume },
	{ .name = "audio.set_mute", .summary = "Mute or unmute a device: {flow, id, muted}.", .run = &set_mute },
	{ .name = "audio.set_default", .summary = "Make a device the default: {flow, id}.", .run = &set_default },
};

const registry::Spec AUDIO = {
	.name = "audio",
	.summary = "Devices, default route, volume and streams (PulseAudio, CoreAudio, WASAPI)",
	.open = &open,
	.close = &live::close{audio::Audio, audio::State, audio::Cap},
	.state = &live::state{audio::Audio, audio::State, audio::Cap},
	.state_after = &live::state_after{audio::Audio, audio::State, audio::Cap},
	.capabilities = &live::capabilities{audio::Audio, audio::State, audio::Cap},
	.backend = &live::backend{audio::Audio, audio::State, audio::Cap},
	.watch = &tap::watch{audio::Audio, audio::State},
	.commands = COMMANDS[..],
};
