<*
 Decoders for the records a PulseAudio server sends: server info, sinks and
 sources, cards, and playback and record streams.

 Each decoder follows the encoder in the upstream server (pulsecore/
 protocol-native.c) field by field, gated on the protocol version exactly as
 the encoder is. The gates are the ones the server writes:
 sink and source   proplist 13, base volume and state and card 15,
 ports 16 (availability 24, group and type 34),
 formats 21 for sinks and 22 for sources (not the same)
 sink input        mute 11, proplist 13, corked 19, has_volume and
 writable 20, format 21
 source output     proplist 13, corked 19, volume, mute, has_volume and
 writable 22, format 22
 card              profile availability 29, ports 26 (latency offset 27,
 group and type 34)
 Sources: protocol-native.c sink_fill_tagstruct 3164-3238,
 source_fill_tagstruct 3239-3313, card_fill_tagstruct 3327-3385,
 sink_input_fill_tagstruct 3402-3444, source_output_fill_tagstruct 3445-3485,
 command_get_server_info 3678-3705 (all in the upstream master tree).

 Strings and slices point into the packet. Anything kept longer must be copied
 by the caller; the state builder (pulse_state.c3) does that.
*>
module bleu::audio::pulse;
import bleu::error;

// Protocol versions at which a field appears (the gates listed above).
const uint V_PROPLIST             = 13;
const uint V_CARD_AND_BASE_VOLUME = 15;
const uint V_PORTS                = 16;
const uint V_PORT_AVAILABILITY    = 24;
const uint V_SINK_FORMATS         = 21;
const uint V_SOURCE_FORMATS       = 22;
const uint V_SINK_INPUT_MUTE      = 11;
const uint V_CORKED               = 19;
const uint V_STREAM_VOLUME_FLAGS  = 20;
const uint V_SOURCE_OUTPUT_VOLUME = 22;
const uint V_PROFILE_AVAILABILITY = 29;
const uint V_CARD_PORTS           = 26;
const uint V_PORT_LATENCY_OFFSET  = 27;
const uint V_PORT_GROUP           = 34;
const uint V_SERVER_CHANNEL_MAP   = 15;

// Device flags (def.h:801-832): HW_VOLUME_CTRL 0x1, HW_MUTE_CTRL 0x10.
const uint FLAG_HW_VOLUME_CTRL = 0x0001;
const uint FLAG_HW_MUTE_CTRL   = 0x0010;

<* What the server says about itself and its defaults. *>
struct ServerInfo
{
	String server_name;
	String version;
	String default_sink; // name of the default output; "" when none
	String default_source; // name of the default input; "" when none
	uint cookie;
}

<* Decode GET_SERVER_INFO. The default names are the ids to compare against. *>
fn ServerInfo? read_server_info(TagReader* r, uint version)
{
	ServerInfo info;
	info.server_name = r.string()!;
	info.version = r.string()!;
	r.string()!; // user name
	r.string()!; // host name
	r.sample_spec_channels()!;
	info.default_sink = r.string()!;
	info.default_source = r.string()!;
	info.cookie = r.u32()!;
	if (version >= V_SERVER_CHANNEL_MAP) r.channel_map()!;
	return info;
}

<* One port of a device. `available` is the raw PA_PORT_AVAILABLE_* value. *>
struct PortRecord
{
	String name;
	String description;
	uint priority;
	uint available; // 0 unknown, 1 no, 2 yes; 0 before protocol 24
	String group; // availability group, "" before protocol 34
	uint type; // port type, 0 before protocol 34
}

<* A sink or a source: both records have the same layout up to the format list. *>
struct DeviceRecord
{
	uint index;
	String name;
	String description;
	CVolume volume;
	ChannelMap channel_map;
	bool muted;
	uint monitor_index; // for a sink: its monitor source; for a source: the sink it monitors (NO_INDEX if none)
	String monitor_name;
	uint flags;
	Property[] props;
	uint card_index; // NO_INDEX when the device has no card
	PortRecord[] ports;
	String active_port; // "" when none
}

<*
 Decode one sink (`is_source` false) or source record.

 @param allocator : "Allocator for the property and port slices"
 @return? error::PROTOCOL : "the packet does not match the layout"
*>
fn DeviceRecord? read_device(TagReader* r, uint version, bool is_source, Allocator allocator)
{
	DeviceRecord d;
	d.index = r.u32()!;
	d.name = r.string()!;
	d.description = r.string()!;
	r.sample_spec_channels()!;
	d.channel_map = r.channel_map()!;
	r.u32()!; // owning module
	d.volume = r.cvolume()!;
	d.muted = r.flag()!;
	d.monitor_index = r.u32()!;
	d.monitor_name = r.string()!;
	r.usec()!; // latency
	r.string()!; // driver
	d.flags = r.u32()!;
	d.card_index = NO_INDEX;
	if (version >= V_PROPLIST)
	{
		d.props = r.proplist(allocator)!;
		r.usec()!; // requested latency
	}
	if (version >= V_CARD_AND_BASE_VOLUME)
	{
		r.volume()!; // base volume
		r.u32()!; // state: running, idle or suspended
		r.u32()!; // volume steps
		d.card_index = r.u32()!;
	}
	if (version >= V_PORTS)
	{
		d.ports = read_ports(r, version, allocator)!;
		d.active_port = r.string()!;
	}
	uint format_gate = is_source ? V_SOURCE_FORMATS : V_SINK_FORMATS;
	if (version >= format_gate)
	{
		char formats = r.u8()!;
		for (char i = 0; i < formats; i++) r.skip_format_info()!;
	}
	return d;
}

// The port list of a device or card record; the count is a u32 (pulsecore/protocol-native.c:3203-3222).
fn PortRecord[]? read_ports(TagReader* r, uint version, Allocator allocator)
{
	uint count         = r.u32()!;
	PortRecord[] ports = alloc::new_array(allocator, PortRecord, (sz)count);
	for (uint i = 0; i < count; i++)
	{
		PortRecord port;
		port.name = r.string()!;
		port.description = r.string()!;
		port.priority = r.u32()!;
		if (version >= V_PORT_AVAILABILITY)
		{
			port.available = r.u32()!;
			if (version >= V_PORT_GROUP)
			{
				port.group = r.string()!;
				port.type = r.u32()!;
			}
		}
		ports[i] = port;
	}
	return ports;
}

<* A card profile: a set of devices the card can expose (protocol-native.c:3327-3360). *>
struct ProfileRecord
{
	String name;
	String description;
	uint sinks;
	uint sources;
	uint priority;
	bool available;
}

<* A card. `active_profile` is the profile in use. *>
struct CardRecord
{
	uint index;
	String name;
	String driver;
	Property[] props;
	ProfileRecord[] profiles;
	String active_profile;
}

<* Decode one card record. Ports are read and discarded: the model does not carry them. *>
fn CardRecord? read_card(TagReader* r, uint version, Allocator allocator)
{
	CardRecord card;
	card.index = r.u32()!;
	card.name = r.string()!;
	r.u32()!; // owning module
	card.driver = r.string()!;
	uint count = r.u32()!;
	card.profiles = alloc::new_array(allocator, ProfileRecord, (sz)count);
	for (uint i = 0; i < count; i++)
	{
		ProfileRecord p;
		p.name = r.string()!;
		p.description = r.string()!;
		p.sinks = r.u32()!;
		p.sources = r.u32()!;
		p.priority = r.u32()!;
		if (version >= V_PROFILE_AVAILABILITY) p.available = r.u32()! != 0;
		card.profiles[i] = p;
	}
	card.active_profile = r.string()!;
	card.props = r.proplist(allocator)!;
	if (version >= V_CARD_PORTS) skip_card_ports(r, version)!;
	return card;
}

// Card ports: read to keep the packet aligned, not kept (protocol-native.c:3354-3383).
fn void? skip_card_ports(TagReader* r, uint version)
{
	uint count = r.u32()!;
	for (uint i = 0; i < count; i++)
	{
		r.string()!;
		r.string()!;
		r.u32()!; // priority
		r.u32()!; // available
		r.u8()!; // direction
		r.proplist(tmem)!;
		uint profiles = r.u32()!;
		for (uint j = 0; j < profiles; j++) r.string()!;
		if (version >= V_PORT_LATENCY_OFFSET) r.s64()!;
		if (version >= V_PORT_GROUP)
		{
			r.string()!;
			r.u32()!;
		}
	}
}

<* A signed 64-bit value: 'r' and eight bytes. Only skipped, never kept. *>
fn void? TagReader.s64(&self)
{
	self.expect(TAG_S64)!;
	self.raw(8)!;
}

<*
 A playback stream (sink input) or a record stream (source output). The
 layouts differ: a source output carries its volume only from protocol 22.
*>
struct StreamRecord
{
	uint index;
	String media_name;
	uint device_index; // sink index for playback, source index for record
	CVolume volume;
	bool has_volume;
	bool volume_writable;
	bool muted;
	bool corked;
	Property[] props;
}

<* Decode a sink input (playback stream). *>
fn StreamRecord? read_sink_input(TagReader* r, uint version, Allocator allocator)
{
	StreamRecord s;
	s.index = r.u32()!;
	s.media_name = r.string()!;
	r.u32()!; // module
	r.u32()!; // client
	s.device_index = r.u32()!;
	r.sample_spec_channels()!;
	r.channel_map()!;
	s.volume = r.cvolume()!;
	r.usec()!; // latency
	r.usec()!; // sink latency
	r.string()!; // resample method
	r.string()!; // driver
	if (version >= V_SINK_INPUT_MUTE) s.muted = r.flag()!;
	if (version >= V_PROPLIST) s.props = r.proplist(allocator)!;
	if (version >= V_CORKED) s.corked = r.flag()!;
	if (version >= V_STREAM_VOLUME_FLAGS)
	{
		s.has_volume = r.flag()!;
		s.volume_writable = r.flag()!;
	}
	if (version >= V_SINK_FORMATS) r.skip_format_info()!;
	return s;
}

<* Decode a source output (record stream). *>
fn StreamRecord? read_source_output(TagReader* r, uint version, Allocator allocator)
{
	StreamRecord s;
	s.index = r.u32()!;
	s.media_name = r.string()!;
	r.u32()!; // module
	r.u32()!; // client
	s.device_index = r.u32()!;
	r.sample_spec_channels()!;
	r.channel_map()!;
	r.usec()!; // latency
	r.usec()!; // source latency
	r.string()!; // resample method
	r.string()!; // driver
	if (version >= V_PROPLIST) s.props = r.proplist(allocator)!;
	if (version >= V_CORKED) s.corked = r.flag()!;
	if (version >= V_SOURCE_OUTPUT_VOLUME)
	{
		s.volume = r.cvolume()!;
		s.muted = r.flag()!;
		s.has_volume = r.flag()!;
		s.volume_writable = r.flag()!;
		r.skip_format_info()!;
	}
	return s;
}

<* Decode a list reply: records follow one another with no count (protocol-native.c:3654-3656). *>
fn void? TagReader.expect_end(&self)
{
	if (!self.at_end()) return error::raise(
		error::PROTOCOL,
		error::Domain.PULSE,
		0,
		"%d bytes after the last record",
		self.data.len - self.pos
	)~;
}