<* The `media` entry of the registry: open adapter, commands and `Spec`. *>
module bleu::registry::svc_media;
import std::time, bleu::media, bleu::registry, bleu::registry::live, bleu::json, bleu::registry::tap;

<* Open the media service with its default backend. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	media::Media* service = media::open(allocator)!;
	return (void*)service;
}

<* Wait for a transport command on `player` and write the success object. *>
fn void? transport(registry::Request* request, media::CommandOp* operation) @private
{
	defer operation.release();
	registry::await{bool}(operation, request.timeout)!;
	return registry::write_ok(request.out);
}

<* `media.play {player}`: start playback. *>
fn void? play(registry::Request* request)
{
	media::Media* service = (media::Media*)request.handle;
	return transport(request, service.play((ulong)request.params.integer("player")!)!);
}

<* `media.pause {player}`: pause playback. *>
fn void? pause(registry::Request* request)
{
	media::Media* service = (media::Media*)request.handle;
	return transport(request, service.pause((ulong)request.params.integer("player")!)!);
}

<* `media.play_pause {player}`: toggle playback. *>
fn void? play_pause(registry::Request* request)
{
	media::Media* service = (media::Media*)request.handle;
	return transport(request, service.play_pause((ulong)request.params.integer("player")!)!);
}

<* `media.next {player}`: skip to the next track. *>
fn void? next(registry::Request* request)
{
	media::Media* service = (media::Media*)request.handle;
	return transport(request, service.next((ulong)request.params.integer("player")!)!);
}

<* `media.previous {player}`: go to the previous track. *>
fn void? previous(registry::Request* request)
{
	media::Media* service = (media::Media*)request.handle;
	return transport(request, service.previous((ulong)request.params.integer("player")!)!);
}

<* `media.seek {player, offset_us}`: move the position by a signed number of microseconds. *>
fn void? seek(registry::Request* request)
{
	media::Media* service = (media::Media*)request.handle;
	ulong player = (ulong)request.params.integer("player")!;
	Duration offset = (Duration)request.params.integer("offset_us")!;
	return transport(request, service.seek(player, offset)!);
}

const registry::Command[6] COMMANDS = {
	{ .name = "media.play", .summary = "Start playback: {player}.", .run = &play },
	{ .name = "media.pause", .summary = "Pause playback: {player}.", .run = &pause },
	{ .name = "media.play_pause", .summary = "Toggle playback: {player}.", .run = &play_pause },
	{ .name = "media.next", .summary = "Next track: {player}.", .run = &next },
	{ .name = "media.previous", .summary = "Previous track: {player}.", .run = &previous },
	{ .name = "media.seek", .summary = "Seek by a signed offset: {player, offset_us}.", .run = &seek },
};

const registry::Spec MEDIA = {
	.name = "media",
	.summary = "Players, now playing and transport (MPRIS, SMTC, scripting)",
	.open = &open,
	.close = &live::close{media::Media, media::State, media::Cap},
	.state = &live::state{media::Media, media::State, media::Cap},
	.state_after = &live::state_after{media::Media, media::State, media::Cap},
	.capabilities = &live::capabilities{media::Media, media::State, media::Cap},
	.backend = &live::backend{media::Media, media::State, media::Cap},
	.watch = &tap::watch{media::Media, media::State},
	.commands = COMMANDS[..],
};
