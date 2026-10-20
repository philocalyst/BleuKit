<*
 Executing queued commands on the session. Each one sends its request and
 waits for the server's answer; the change itself reaches the state through
 the next refresh, which the server's subscription event triggers.
*>
module bleu::audio::linux_pulse @feat(LINUX);
import bleu::error, bleu::unit, bleu::audio, bleu::audio::pulse;

<* Raw server volumes of the gains in a command, into `raw`. @return? error::INVALID_ARGUMENT : "no channels, or more than pulse::CHANNELS_MAX" *>
fn uint[]? raw_volumes(Gain[] gains, uint[pulse::CHANNELS_MAX]* raw) @private
{
	if (gains.len == 0 || gains.len > pulse::CHANNELS_MAX) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "%d channels, 1 to %d allowed", gains.len, pulse::CHANNELS_MAX)~;
	for (sz i = 0; i < gains.len; i++) (*raw)[i] = pulse::raw_from_gain(gains[i]);
	return (*raw)[0 : gains.len];
}

<* A stream id is the server's index as text. @return? error::INVALID_ARGUMENT : "not an index" *>
fn uint? stream_index(String id) @private
{
	long? index = id.to_long();
	if (catch err = index) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "'%s' is not a stream id", id)~;
	if (index < 0 || index >= (long)pulse::NO_INDEX) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "stream id %d out of range", index)~;
	return (uint)index;
}

<* Run one command to completion on the session. *>
fn void? Session.execute(&self, Command* command)
{
	@pool()
	{
		uint[pulse::CHANNELS_MAX] raw;
		uint tag = self.next_tag++;
		bool input = command.flow == Flow.INPUT;
		DString request;
		uint[] values;
		uint stream = 0;
		switch (command.kind)
		{
			case CommandKind.REFRESH:
				return;
			case CommandKind.SET_DEVICE_VOLUME:
				values = raw_volumes(command.gains, &raw)!;
				request = pulse::request_set_device_volume(tmem, tag, input, pulse::NO_INDEX, command.target, values);
			case CommandKind.SET_DEVICE_MUTE:
				request = pulse::request_set_device_mute(tmem, tag, input, pulse::NO_INDEX, command.target, command.flag);
			case CommandKind.SET_DEFAULT:
				request = pulse::request_set_default(tmem, tag, input, command.target);
			case CommandKind.SET_STREAM_VOLUME:
				stream = stream_index(command.target)!;
				values = raw_volumes(command.gains, &raw)!;
				request = pulse::request_set_stream_volume(tmem, tag, input, stream, values);
			case CommandKind.SET_STREAM_MUTE:
				stream = stream_index(command.target)!;
				request = pulse::request_set_stream_mute(tmem, tag, input, stream, command.flag);
			case CommandKind.MOVE_STREAM:
				stream = stream_index(command.target)!;
				request = pulse::request_move_stream(tmem, tag, input, stream, pulse::NO_INDEX, command.choice);
			case CommandKind.SET_PORT:
				request = pulse::request_set_port(tmem, tag, input, pulse::NO_INDEX, command.target, command.choice);
			case CommandKind.SET_CARD_PROFILE:
				request = pulse::request_set_card_profile(tmem, tag, pulse::NO_INDEX, command.target, command.choice);
		}
		self.acknowledge(&request, tag)!;
	};
}
