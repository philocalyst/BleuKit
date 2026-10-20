<*
 What changed between two states, as events. Pure: a backend publishes a
 whole new state and this reports the difference, so every backend emits the
 same events for the same change.

 An event names the object it concerns. Consumers re-read the state for
 values; the strings in an event are valid only during the callback.
*>
module bleu::audio;
import bleu::equal;

<* Receives one event. Called on the publishing thread. *>
alias EmitFn = fn void(void* context, Event event);

<* Emit the events that turn `before` into `after`. *>
fn void report_changes(State* before, State* after, void* context, EmitFn emit)
{
	report_devices(before.outputs, after.outputs, OUTPUT, context, emit);
	report_devices(before.inputs, after.inputs, INPUT, context, emit);
	report_streams(before.streams, after.streams, context, emit);
	report_cards(before.cards, after.cards, context, emit);
	if (before.default_output != after.default_output) emit(context, { DEFAULT_CHANGED, OUTPUT, after.default_output });
	if (before.default_input != after.default_input) emit(context, { DEFAULT_CHANGED, INPUT, after.default_input });
	if (before.mic_in_use != after.mic_in_use) emit(context, { MIC_IN_USE_CHANGED, INPUT, "" });
}

fn void report_devices(Device[] before, Device[] after, Flow flow, void* context, EmitFn emit) @private
{
	foreach (&d : after)
	{
		Device* old = find_device(before, d.id);
		if (!old)
		{
			emit(context, { DEVICE_ADDED, flow, d.id });
		}
		else if (!equal::deep(*old, *d))
		{
			emit(context, { DEVICE_CHANGED, flow, d.id });
		}
	}
	foreach (&d : before)
	{
		if (!find_device(after, d.id)) emit(context, { DEVICE_REMOVED, flow, d.id });
	}
}

fn void report_streams(Stream[] before, Stream[] after, void* context, EmitFn emit) @private
{
	foreach (&s : after)
	{
		Stream* old = find_stream(before, s.id);
		if (!old)
		{
			emit(context, { STREAM_ADDED, s.flow, s.id });
		}
		else if (!equal::deep(*old, *s))
		{
			emit(context, { STREAM_CHANGED, s.flow, s.id });
		}
	}
	foreach (&s : before)
	{
		if (!find_stream(after, s.id)) emit(context, { STREAM_REMOVED, s.flow, s.id });
	}
}

fn void report_cards(Card[] before, Card[] after, void* context, EmitFn emit) @private
{
	foreach (&c : after)
	{
		Card* old = find_card(before, c.id);
		if (!old || !equal::deep(*old, *c)) emit(context, { CARD_CHANGED, OUTPUT, c.id });
	}
}

<* The device with `id`, or null. Used by the diff and by commands that refer to a device. *>
fn Device* find_device(Device[] devices, String id)
{
	foreach (&d : devices)
	{
		if (d.id == id) return d;
	}
	return null;
}

fn Stream* find_stream(Stream[] streams, String id)
{
	foreach (&s : streams)
	{
		if (s.id == id) return s;
	}
	return null;
}

fn Card* find_card(Card[] cards, String id)
{
	foreach (&c : cards)
	{
		if (c.id == id) return c;
	}
	return null;
}
