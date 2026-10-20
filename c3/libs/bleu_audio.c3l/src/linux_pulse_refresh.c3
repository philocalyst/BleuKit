<*
 Reading the whole server state and publishing it.

 One refresh is one round of queries: server info, then the sinks, the
 sources, the playback and record streams, and the cards. Each list reply
 holds its records back to back with no count (protocol-native.c:3654-3656),
 so a list is read until the packet ends. The state is then built into a
 fresh snapshot and published through the shared change check.
*>
module bleu::audio::linux_pulse @feat(LINUX);
import bleu::error, bleu::observe, bleu::audio, bleu::audio::pulse, std::collections::list;

<* Run one list (or single) query and return its reply reader. *>
fn TagReader? Session.query(&self, PulseCommand command)
{
	uint tag        = self.next_tag++;
	DString request = pulse::request_empty(tmem, command, tag);
	return self.call(&request, tag);
}

fn pulse::ServerInfo? Session.read_server(&self)
{
	TagReader reply = self.query(PulseCommand.GET_SERVER_INFO)!;
	return pulse::read_server_info(&reply, self.version);
}

<* One device by name, as the server resolves it (used for the default-device aliases). *>
fn pulse::DeviceRecord? Session.read_device_info(&self, bool is_source, String name, Allocator allocator)
{
	uint tag        = self.next_tag++;
	DString request = pulse::request_get_device_info(tmem, tag, is_source, pulse::NO_INDEX, name);
	TagReader reply = self.call(&request, tag)!;
	return pulse::read_device(&reply, self.version, is_source, allocator);
}

<* Every device record of a sink or source list. *>
fn DeviceRecord[]? Session.read_devices(&self, PulseCommand command, bool is_source, Allocator allocator)
{
	TagReader reply = self.query(command)!;
	List{DeviceRecord} devices;
	devices.init(allocator);
	while (!reply.at_end())
	{
		devices.push(pulse::read_device(&reply, self.version, is_source, allocator)!);
	}
	return devices.array_view();
}

fn StreamRecord[]? Session.read_streams(&self, PulseCommand command, bool is_source_output, Allocator allocator)
{
	TagReader reply = self.query(command)!;
	List{StreamRecord} streams;
	streams.init(allocator);
	while (!reply.at_end())
	{
		StreamRecord stream = is_source_output ? pulse::read_source_output(&reply, self.version, allocator)!
			: pulse::read_sink_input(&reply, self.version, allocator)!;
		streams.push(stream);
	}
	return streams.array_view();
}

fn CardRecord[]? Session.read_cards(&self, Allocator allocator)
{
	TagReader reply = self.query(PulseCommand.GET_CARD_INFO_LIST)!;
	List{CardRecord} cards;
	cards.init(allocator);
	while (!reply.at_end())
	{
		cards.push(pulse::read_card(&reply, self.version, allocator)!);
	}
	return cards.array_view();
}

<*
 The name of the default device. A server that reports the protocol's alias
 ("@DEFAULT_SINK@") is asked for the device it stands for; when it cannot say (as
 pipewire-pulse 1.0.5 does), the default is reported as none. A server that gives a
 name, or none, is taken as it is.
*>
fn String? Session.resolve_default(&self, String name, bool is_source)
{
	String placeholder = is_source ? pulse::DEFAULT_SOURCE_ALIAS : pulse::DEFAULT_SINK_ALIAS;
	if (name != placeholder) return name;
	pulse::DeviceRecord? device = self.read_device_info(is_source, name, tmem);
	if (catch err = device)
	{
		// pipewire-pulse 1.0.5 answers NOENTITY to the alias: it cannot say which device is default.
		if (err == NOT_FOUND) return "";
		return err~;
	}
	return device.name;
}

<* Query everything, build the state and publish it if it changed. *>
fn void? Session.refresh(&self, AudioHub* hub)
{
	@pool()
	{
		pulse::Records records;
		records.server = self.read_server()!;
		records.server.default_sink = self.resolve_default(records.server.default_sink, false)!;
		records.server.default_source = self.resolve_default(records.server.default_source, true)!;
		records.sinks = self.read_devices(PulseCommand.GET_SINK_INFO_LIST, false, tmem)!;
		records.sources = self.read_devices(PulseCommand.GET_SOURCE_INFO_LIST, true, tmem)!;
		records.sink_inputs = self.read_streams(PulseCommand.GET_SINK_INPUT_INFO_LIST, false, tmem)!;
		records.source_outputs = self.read_streams(PulseCommand.GET_SOURCE_OUTPUT_INFO_LIST, true, tmem)!;
		records.cards = self.read_cards(tmem)!;
		Snapshot{State}* snapshot = hub.begin();
		State? state              = pulse::build_state(snapshot.allocator(), &records);
		if (catch err = state)
		{
			snapshot.release();
			return err~;
		}
		snapshot.value = state;
		audio::publish_snapshot(hub, snapshot);
	};
}