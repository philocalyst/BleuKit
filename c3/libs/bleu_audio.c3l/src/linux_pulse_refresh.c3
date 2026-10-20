<*
 Reading the whole server state and publishing it.

 One refresh is one round of queries: server info, then the sinks, the
 sources, the playback and record streams, and the cards. Each list reply
 holds its records back to back with no count (protocol-native.c:3654-3656),
 so a list is read until the packet ends. A record that does not decode
 (a layout this client does not know) ends its list: the records before it are
 kept, and the rest of that list cannot be located, so it is dropped and noted
 in `State.degraded`. Each list is its own reply, so the other lists still
 publish. The state is then built into a fresh snapshot and published through
 the shared change check.
*>
module bleu::audio::linux_pulse @feat(LINUX);
import bleu::error, bleu::observe, bleu::audio, bleu::audio::pulse, std::collections::list;

<*
 Note a list that stopped early in `degraded`; the notes are joined with "; ".
 Only an undecodable record gets here: a failed request is still an error.
*>
fn void note_skipped(String* degraded, String list, sz kept) @private
{
	String note = string::tformat("%s: stopped after %d records, the next one does not decode", list, kept);
	*degraded = degraded.len == 0 ? note : string::tformat("%s; %s", *degraded, note);
}

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
fn DeviceRecord[]? Session.read_devices(
	&self,
	PulseCommand command,
	bool is_source,
	Allocator allocator,
	String* degraded
)
{
	TagReader reply = self.query(command)!;
	List{DeviceRecord} devices;
	devices.init(allocator);
	while (!reply.at_end())
	{
		DeviceRecord? device = pulse::read_device(&reply, self.version, is_source, allocator);
		if (catch device)
		{
			note_skipped(degraded, is_source ? "sources" : "sinks", devices.len());
			break;
		}
		devices.push(device);
	}
	return devices.array_view();
}

fn StreamRecord[]? Session.read_streams(
	&self,
	PulseCommand command,
	bool is_source_output,
	Allocator allocator,
	String* degraded
)
{
	TagReader reply = self.query(command)!;
	List{StreamRecord} streams;
	streams.init(allocator);
	while (!reply.at_end())
	{
		StreamRecord? stream = is_source_output ? pulse::read_source_output(&reply, self.version, allocator)
			: pulse::read_sink_input(&reply, self.version, allocator);
		if (catch stream)
		{
			note_skipped(degraded, is_source_output ? "source outputs" : "sink inputs", streams.len());
			break;
		}
		streams.push(stream);
	}
	return streams.array_view();
}

fn CardRecord[]? Session.read_cards(&self, Allocator allocator, String* degraded)
{
	TagReader reply = self.query(PulseCommand.GET_CARD_INFO_LIST)!;
	List{CardRecord} cards;
	cards.init(allocator);
	while (!reply.at_end())
	{
		CardRecord? card = pulse::read_card(&reply, self.version, allocator);
		if (catch card)
		{
			note_skipped(degraded, "cards", cards.len());
			break;
		}
		cards.push(card);
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
		records.degraded = "";
		records.sinks = self.read_devices(PulseCommand.GET_SINK_INFO_LIST, false, tmem, &records.degraded)!;
		records.sources = self.read_devices(PulseCommand.GET_SOURCE_INFO_LIST, true, tmem, &records.degraded)!;
		records.sink_inputs = self.read_streams(
			PulseCommand.GET_SINK_INPUT_INFO_LIST,
			false,
			tmem,
			&records.degraded
		)!;
		records.source_outputs = self.read_streams(
			PulseCommand.GET_SOURCE_OUTPUT_INFO_LIST,
			true,
			tmem,
			&records.degraded
		)!;
		records.cards = self.read_cards(tmem, &records.degraded)!;
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