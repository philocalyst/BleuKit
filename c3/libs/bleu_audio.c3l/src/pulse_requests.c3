<*
 Request encoders: each returns one complete command packet (frame header
 included), ready to write to the socket. Pure: nothing is sent here.

 Argument layouts come from the upstream server's parsers in
 protocol-native.c:
 AUTH                      u32 version, arbitrary cookie (command_auth, 2567-2576)
 SET_CLIENT_NAME           proplist (command_set_client_name, 2763-2765)
 GET_*_INFO_LIST           no arguments
 SUBSCRIBE                 u32 mask (command_subscribe, 3737-3745)
 SET_SINK_VOLUME           u32 index, string name, cvolume (3786-3789)
 SET_SINK_INPUT_VOLUME     u32 index, cvolume (no name)
 SET_SINK_MUTE             u32 index, string name, boolean (3882-3885)
 SET_SINK_INPUT_MUTE       u32 index, boolean
 SET_DEFAULT_SINK          string name (4398-4402)
 MOVE_SINK_INPUT           u32 index, u32 device index, string device name (4560-4567)
 SET_SINK_PORT             u32 index, string name, string port (4840-4846)
 SET_CARD_PROFILE          u32 index, string name, string profile (4799-4802)
 Where a command takes an index or a name, exactly one is valid: pass
 `NO_INDEX` for the index you do not use, and "" for the name you do not use.
*>
module bleu::audio::pulse;

<* A name argument: the string, or NULL when the caller passed "" (the server then uses the index). *>
fn void put_name_or_null(DString* out, String name) @private
{
	if (name.len == 0)
	{
		put_null_string(out);
		return;
	}
	put_string(out, name);
}

<* AUTH: the protocol version this client speaks and the cookie (256 bytes). *>
fn DString request_auth(Allocator allocator, uint tag, char[] cookie)
{
	DString packet = begin_command(allocator, PulseCommand.AUTH, tag);
	put_u32(&packet, PROTOCOL_VERSION);
	put_arbitrary(&packet, cookie);
	return packet;
}

<* SET_CLIENT_NAME: the client's proplist (application.name and friends). *>
fn DString request_set_client_name(Allocator allocator, uint tag, Property[] props)
{
	DString packet = begin_command(allocator, PulseCommand.SET_CLIENT_NAME, tag);
	put_proplist(&packet, props);
	return packet;
}

<* A request with no arguments: GET_SERVER_INFO and the GET_*_INFO_LIST commands. *>
fn DString request_empty(Allocator allocator, PulseCommand command, uint tag)
{
	return begin_command(allocator, command, tag);
}

<*
 GET_SINK_INFO or GET_SOURCE_INFO: one device by index or name. The reply is one
 record in the same layout as a list entry (command_get_info, protocol-native.c:3518).
*>
fn DString request_get_device_info(Allocator allocator, uint tag, bool is_source, uint index, String name)
{
	DString packet = begin_command(
		allocator,
		is_source ? PulseCommand.GET_SOURCE_INFO : PulseCommand.GET_SINK_INFO,
		tag
	);
	put_u32(&packet, index);
	put_name_or_null(&packet, name);
	return packet;
}

<* SUBSCRIBE: the event facilities to receive; 0 unsubscribes. *>
fn DString request_subscribe(Allocator allocator, uint tag, uint mask)
{
	DString packet = begin_command(allocator, PulseCommand.SUBSCRIBE, tag);
	put_u32(&packet, mask);
	return packet;
}

<*
 Set a sink's or source's channel volumes.

 @param is_source : "true for a source (input device), false for a sink"
 @param index : "the device index, or NO_INDEX to address it by name"
 @param name : "the device name, used when `index` is NO_INDEX"
 @require values.len <= CHANNELS_MAX : "a volume carries at most CHANNELS_MAX channels"
*>
fn DString request_set_device_volume(
	Allocator allocator,
	uint tag,
	bool is_source,
	uint index,
	String name,
	uint[] values
)
{
	DString packet = begin_command(
		allocator,
		is_source ? PulseCommand.SET_SOURCE_VOLUME : PulseCommand.SET_SINK_VOLUME,
		tag
	);
	put_u32(&packet, index);
	put_name_or_null(&packet, name);
	put_cvolume(&packet, values);
	return packet;
}

<*
 Set a playback stream's (sink input) or record stream's (source output)
 channel volumes. Streams are addressed by index only.
*>
fn DString request_set_stream_volume(Allocator allocator, uint tag, bool is_source_output, uint index, uint[] values)
{
	DString packet = begin_command(
		allocator,
		is_source_output ? PulseCommand.SET_SOURCE_OUTPUT_VOLUME : PulseCommand.SET_SINK_INPUT_VOLUME,
		tag
	);
	put_u32(&packet, index);
	put_cvolume(&packet, values);
	return packet;
}

<* Mute or unmute a device (sink or source). Mute is a flag, not volume zero. *>
fn DString request_set_device_mute(Allocator allocator, uint tag, bool is_source, uint index, String name, bool muted)
{
	DString packet = begin_command(
		allocator,
		is_source ? PulseCommand.SET_SOURCE_MUTE : PulseCommand.SET_SINK_MUTE,
		tag
	);
	put_u32(&packet, index);
	put_name_or_null(&packet, name);
	put_bool(&packet, muted);
	return packet;
}

<* Mute or unmute a stream. Streams are addressed by index only. *>
fn DString request_set_stream_mute(Allocator allocator, uint tag, bool is_source_output, uint index, bool muted)
{
	DString packet = begin_command(
		allocator,
		is_source_output ? PulseCommand.SET_SOURCE_OUTPUT_MUTE : PulseCommand.SET_SINK_INPUT_MUTE,
		tag
	);
	put_u32(&packet, index);
	put_bool(&packet, muted);
	return packet;
}

<* Make a sink or source the default. An empty name is not accepted by the server. *>
fn DString request_set_default(Allocator allocator, uint tag, bool is_source, String name)
{
	DString packet = begin_command(
		allocator,
		is_source ? PulseCommand.SET_DEFAULT_SOURCE : PulseCommand.SET_DEFAULT_SINK,
		tag
	);
	put_string(&packet, name);
	return packet;
}

<*
 Move a stream to another device. The device is named by index or by name;
 the name string is always present on the wire, so pass "" when using the index.
*>
fn DString request_move_stream(
	Allocator allocator,
	uint tag,
	bool is_source_output,
	uint stream_index,
	uint device_index,
	String device_name
)
{
	DString packet = begin_command(
		allocator,
		is_source_output ? PulseCommand.MOVE_SOURCE_OUTPUT : PulseCommand.MOVE_SINK_INPUT,
		tag
	);
	put_u32(&packet, stream_index);
	put_u32(&packet, device_index);
	put_name_or_null(&packet, device_name);
	return packet;
}

<* Choose a device's active port by name. Address the device by index or by name. *>
fn DString request_set_port(Allocator allocator, uint tag, bool is_source, uint index, String name, String port)
{
	DString packet = begin_command(
		allocator,
		is_source ? PulseCommand.SET_SOURCE_PORT : PulseCommand.SET_SINK_PORT,
		tag
	);
	put_u32(&packet, index);
	put_name_or_null(&packet, name);
	put_string(&packet, port);
	return packet;
}

<* Choose a card's profile. Address the card by index or by name. *>
fn DString request_set_card_profile(Allocator allocator, uint tag, uint index, String name, String profile)
{
	DString packet = begin_command(allocator, PulseCommand.SET_CARD_PROFILE, tag);
	put_u32(&packet, index);
	put_name_or_null(&packet, name);
	put_string(&packet, profile);
	return packet;
}