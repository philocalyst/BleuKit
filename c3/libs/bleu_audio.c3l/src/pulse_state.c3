<*
 From the records a PulseAudio server sent to the model's `State`.

 Pure: it reads records and writes one complete `State` whose strings and
 slices come from the allocator given (the snapshot arena). Nothing from the
 packets is kept after this returns.

 Property names are the server's proplist keys (pulse/proplist.h:144-223,
 device keys :188-223): application.name, application.id,
 application.icon_name, application.process.binary, application.process.id,
 media.name, device.form_factor (values listed in proplist.h:212), device.bus
 (proplist.h:215: isa, pci, usb, firewire, bluetooth).
*>
module bleu::audio::pulse;
import std::collections::maybe, bleu::audio, bleu::unit, bleu::error, bleu::audio::volume;

<* The records one refresh read: everything `build_state` needs. *>
struct Records
{
	ServerInfo server;
	DeviceRecord[] sinks;
	DeviceRecord[] sources;
	StreamRecord[] sink_inputs;
	StreamRecord[] source_outputs;
	CardRecord[] cards;
	String degraded; // notes from the reads that stopped early; "" when none
}

<* Build the state. Every string is copied into `allocator`. *>
fn State? build_state(Allocator allocator, Records* records)
{
	State state;
	state.default_output = records.server.default_sink.copy(allocator);
	state.default_input = records.server.default_source.copy(allocator);
	state.cards = cards_of(allocator, records.cards);
	state.outputs = devices_of(allocator, records, records.sinks, OUTPUT, records.server.default_sink);
	state.inputs = inputs_of(allocator, records);
	state.streams = streams_of(allocator, records);
	state.mic_in_use = mic_in_use(records);
	state.degraded = records.degraded.len > 0 ? records.degraded.copy(allocator) : "";
	return state;
}

// The non-monitor sources: a monitor captures a sink's output and is not a microphone.
fn DeviceRecord[] non_monitor_sources(Allocator allocator, DeviceRecord[] sources) @private
{
	sz count = 0;
	foreach (source : sources)
	{
		if (source.monitor_index == NO_INDEX) count++;
	}
	DeviceRecord[] inputs = alloc::new_array(allocator, DeviceRecord, count);
	sz at                 = 0;
	foreach (source : sources)
	{
		if (source.monitor_index != NO_INDEX) continue;
		inputs[at++] = source;
	}
	return inputs;
}

fn Device[] devices_of(
	Allocator allocator,
	Records* records,
	DeviceRecord[] list,
	Flow flow,
	String default_name
) @private
{
	Device[] devices = alloc::new_array(allocator, Device, list.len);
	foreach (i, &record : list)
	{
		devices[i] = device_of(allocator, records, record, flow, record.name == default_name);
	}
	return devices;
}

fn Device[] inputs_of(Allocator allocator, Records* records) @private
{
	DeviceRecord[] inputs = non_monitor_sources(tmem, records.sources);
	return devices_of(allocator, records, inputs, INPUT, records.server.default_source);
}

fn Device device_of(Allocator allocator, Records* records, DeviceRecord* record, Flow flow, bool is_default) @private
{
	Device device;
	device.id = record.name.copy(allocator);
	device.name = (record.description.len > 0 ? record.description : record.name).copy(allocator);
	device.flow = flow;
	device.form_factor = form_factor_of(record.props, record.name);
	device.bus = bus_of(record.props);
	device.is_default = is_default;
	device.volume = gains_of(allocator, &record.volume);
	device.level = volume::loudest(device.volume).nominal();
	device.balance = balance_of(&record.volume, &record.channel_map);
	device.volume_is_hardware = (record.flags & FLAG_HW_VOLUME_CTRL) != 0;
	device.muted = record.muted;
	device.ports = ports_of(allocator, record.ports, record.active_port);
	device.card_id = card_name(records.cards, record.card_index).copy(allocator);
	return device;
}

<* The form factor from `device.form_factor`, or HDMI for a sink named after HDMI (a heuristic, see the README). *>
fn FormFactor form_factor_of(Property[] props, String name) @private
{
	switch (find_property(props, "device.form_factor"))
	{
		case "internal": return INTERNAL;
		case "speaker": return SPEAKERS;
		case "headphone": return HEADPHONES;
		case "headset":
		case "hands-free": return HEADSET;
		case "handset": return HANDSET;
		case "microphone":
		case "webcam": return MICROPHONE;
		case "car": return CAR;
		case "tv": return TV;
		case "hifi": return HIFI;
		case "portable": return PORTABLE;
		default:
			if (name.contains("hdmi")) return HDMI;
			return UNKNOWN;
	}
}

<* The bus from `device.bus`. Anything else is UNKNOWN. *>
fn Bus bus_of(Property[] props) @private
{
	switch (find_property(props, "device.bus"))
	{
		case "pci": return PCI;
		case "usb": return USB;
		case "bluetooth": return BLUETOOTH;
		default: return UNKNOWN;
	}
}

<* Slider positions of a channel volume, one per channel, in a new slice. *>
fn Gain[] gains_of(Allocator allocator, CVolume* volume) @private
{
	Gain[] gains = alloc::new_array(allocator, Gain, volume.count);
	for (sz i = 0; i < (sz)volume.count; i++) gains[i] = gain_from_raw(volume.values[i]);
	return gains;
}


fn Port[] ports_of(Allocator allocator, PortRecord[] records, String active) @private
{
	Port[] ports = alloc::new_array(allocator, Port, records.len);
	foreach (i, &record : records)
	{
		ports[i] = {
			.id = record.name.copy(allocator),
			.description = record.description.copy(allocator),
			.availability = availability_of(record.available),
			.active = record.name == active,
		};
	}
	return ports;
}

// PA_PORT_AVAILABLE_UNKNOWN 0, NO 1, YES 2 (def.h:1060-1062).
fn PortAvailability availability_of(uint raw) @private
{
	switch (raw)
	{
		case 1: return NO;
		case 2: return YES;
		default: return UNKNOWN;
	}
}

// The name of the card with `index`, or "" when none has it.
fn String card_name(CardRecord[] cards, uint index) @private
{
	if (index == NO_INDEX) return "";
	foreach (card : cards)
	{
		if (card.index == index) return card.name;
	}
	return "";
}

fn Card[] cards_of(Allocator allocator, CardRecord[] records) @private
{
	Card[] cards = alloc::new_array(allocator, Card, records.len);
	foreach (i, &record : records)
	{
		CardProfile[] profiles = alloc::new_array(allocator, CardProfile, record.profiles.len);
		foreach (j, &profile : record.profiles)
		{
			profiles[j] = {
				.id = profile.name.copy(allocator),
				.description = profile.description.copy(allocator),
				.available = profile.available,
				.sinks = profile.sinks,
				.sources = profile.sources,
			};
		}
		String description = find_property(record.props, "device.description");
		cards[i] = {
			.id = record.name.copy(allocator),
			.name = (description.len > 0 ? description : record.name).copy(allocator),
			.active_profile = record.active_profile.copy(allocator),
			.profiles = profiles,
		};
	}
	return cards;
}

// The name of the sink or source with `index`, from the records of that flow; "" when none.
fn String device_name_at(DeviceRecord[] devices, uint index) @private
{
	foreach (device : devices)
	{
		if (device.index == index) return device.name;
	}
	return "";
}

fn Stream[] streams_of(Allocator allocator, Records* records) @private
{
	Stream[] streams = alloc::new_array(allocator, Stream, records.sink_inputs.len + records.source_outputs.len);
	sz at            = 0;
	foreach (&record : records.sink_inputs)
	{
		streams[at++] = stream_of(allocator, record, OUTPUT, device_name_at(records.sinks, record.device_index));
	}
	foreach (&record : records.source_outputs)
	{
		streams[at++] = stream_of(allocator, record, INPUT, device_name_at(records.sources, record.device_index));
	}
	return streams;
}

fn Stream stream_of(Allocator allocator, StreamRecord* record, Flow flow, String device) @private
{
	String app_name = find_property(record.props, "application.name");
	if (app_name.len == 0) app_name = record.media_name;
	String pid_text = find_property(record.props, "application.process.id");
	Stream stream = {
		.id = string::format(allocator, "%d", record.index),
		.flow = flow,
		.app_name = app_name.copy(allocator),
		.app_id = find_property(record.props, "application.id")
		.copy(allocator), .app_icon = find_property(record.props, "application.icon_name")
			.copy(allocator), .binary = find_property(record.props, "application.process.binary")
				.copy(
					allocator
				), .pid = (uint)(long)(pid_text.to_long() ?? 0), .device_id = device.copy(
					allocator
				), .media_name = record.media_name.copy(
					allocator
				), .volume_writable = record.volume_writable, .muted = record.muted, .corked = record.corked, };
	if (record.has_volume) stream.volume = gains_of(allocator, &record.volume);
	return stream;
}

<*
 A microphone is in use when a record stream that is neither muted nor corked
 reads a real input (not a monitor of an output). This is the heuristic of
 the research note (section 2.1.8), without its name filter.
*>
fn bool mic_in_use(Records* records) @private
{
	foreach (&stream : records.source_outputs)
	{
		if (stream.muted || stream.corked) continue;
		if (is_monitor_source(records.sources, stream.device_index)) continue;
		return true;
	}
	return false;
}

fn bool is_monitor_source(DeviceRecord[] sources, uint index) @private
{
	foreach (source : sources)
	{
		if (source.index == index) return source.monitor_index != NO_INDEX;
	}
	return false;
}