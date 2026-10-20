<*
 Reading the CoreAudio device list into the model: one `Device` per flow a
 device has streams in, with its volume, mute, default flag, form factor and bus.
*>
module bleu::audio::macos_devices @feat(DARWIN);
import bleu::audio, bleu::cf, bleu::error, bleu::unit, std::collections::maybe, bleu::audio::volume, bleu::audio::macos_hal;

<* What the HAL says about one device, before it is classified per flow. *>
struct HalDevice
{
	macos_hal::ObjectId id;
	String uid;
	String name;
	uint transport;
	bool has_output;
	bool has_input;
}

// The scope a flow's controls live in.
fn uint scope_of(Flow flow) @inline => flow == Flow.INPUT ? macos_hal::SCOPE_INPUT : macos_hal::SCOPE_OUTPUT;

<* A CFString property, copied into `allocator` as UTF-8 and the CoreFoundation object released. *>
fn String? cf_text(macos_hal::ObjectId object, macos_hal::PropertyAddress address, Allocator allocator) @private
{
	void* raw = null;
	macos_hal::read_property(object, address, &raw, usz::size)!;
	cf::Ref text = cf::adopt(raw);
	defer text.close();
	return cf::string_value(text.ptr, allocator);
}

<* Every device the HAL knows, with identity and stream directions. Strings go into `allocator`. *>
fn HalDevice[]? list_devices(Allocator allocator)
{
	uint size = macos_hal::property_size(
		macos_hal::SYSTEM_OBJECT,
		{ macos_hal::SELECTOR_DEVICES, macos_hal::SCOPE_GLOBAL, macos_hal::ELEMENT_MAIN }
	)!;
	macos_hal::ObjectId[] ids = alloc::new_array(tmem, macos_hal::ObjectId, size / uint::size);
	// The device list can shrink between the size query and this read: only the IDs the HAL wrote are used.
	uint written = macos_hal::read_property_bytes(
		macos_hal::SYSTEM_OBJECT,
		{ macos_hal::SELECTOR_DEVICES, macos_hal::SCOPE_GLOBAL, macos_hal::ELEMENT_MAIN },
		ids.ptr,
		size
	)!;
	sz count            = (sz)(written / uint::size);
	HalDevice[] devices = alloc::new_array(allocator, HalDevice, count);
	for (sz i = 0; i < count; i++)
	{
		devices[i] = {
			.id = ids[i],
			.uid = cf_text(
				ids[i],
				{ macos_hal::SELECTOR_UID, macos_hal::SCOPE_GLOBAL, macos_hal::ELEMENT_MAIN },
				allocator
			)!,
			.name = cf_text(
				ids[i],
				{ macos_hal::SELECTOR_NAME, macos_hal::SCOPE_GLOBAL, macos_hal::ELEMENT_MAIN },
				allocator
			) ?? "",
			.transport = macos_hal::read_u32(
				ids[i],
				{ macos_hal::SELECTOR_TRANSPORT, macos_hal::SCOPE_GLOBAL, macos_hal::ELEMENT_MAIN }
			) ?? 0,
			.has_output = (macos_hal::property_size(
				ids[i],
				{ macos_hal::SELECTOR_STREAMS, macos_hal::SCOPE_OUTPUT, macos_hal::ELEMENT_MAIN }
			) ?? 0) > 0,
			.has_input = (macos_hal::property_size(
				ids[i],
				{ macos_hal::SELECTOR_STREAMS, macos_hal::SCOPE_INPUT, macos_hal::ELEMENT_MAIN }
			) ?? 0) > 0,
		};
	}
	return devices;
}

<* The object id of the device with `uid`, or 0 when none has it. *>
fn macos_hal::ObjectId id_of_uid(HalDevice[] devices, String uid)
{
	foreach (&d : devices)
	{
		if (d.uid == uid) return d.id;
	}
	return 0;
}

<* The form factor from the transport: only what the transport itself says. *>
fn FormFactor form_factor_of(uint transport) @private
{
	switch (transport)
	{
		case macos_hal::TRANSPORT_BUILT_IN: return FormFactor.INTERNAL;
		case macos_hal::TRANSPORT_HDMI:
		case macos_hal::TRANSPORT_DISPLAY_PORT: return FormFactor.HDMI;
		case macos_hal::TRANSPORT_AIRPLAY: return FormFactor.REMOTE_NETWORK;
		default: return FormFactor.UNKNOWN;
	}
}

<* The bus from the transport. *>
fn Bus bus_of(uint transport) @private
{
	switch (transport)
	{
		case macos_hal::TRANSPORT_USB: return Bus.USB;
		case macos_hal::TRANSPORT_BLUETOOTH:
		case macos_hal::TRANSPORT_BLUETOOTH_LE: return Bus.BLUETOOTH;
		case macos_hal::TRANSPORT_PCI: return Bus.PCI;
		case macos_hal::TRANSPORT_VIRTUAL:
		case macos_hal::TRANSPORT_AGGREGATE: return Bus.VIRTUAL;
		case macos_hal::TRANSPORT_BUILT_IN:
		case macos_hal::TRANSPORT_HDMI:
		case macos_hal::TRANSPORT_DISPLAY_PORT:
		case macos_hal::TRANSPORT_AIRPLAY:
		case macos_hal::TRANSPORT_THUNDERBOLT:
		case macos_hal::TRANSPORT_FIREWIRE: return Bus.OTHER;
		default: return Bus.UNKNOWN;
	}
}

<*
 The channel volumes of a flow, on the device's own 0..1 scale. A device with a
 main control has one channel; otherwise the channels 1 and 2 that exist.
 Empty when the device has no volume control in that scope.
*>
fn Gain[]? channel_volumes(Allocator allocator, macos_hal::ObjectId id, Flow flow)
{
	uint scope = scope_of(flow);
	if (macos_hal::has_property(id, { macos_hal::SELECTOR_VOLUME_SCALAR, scope, macos_hal::ELEMENT_MAIN }))
	{
		Gain[] main = alloc::new_array(allocator, Gain, 1);
		main[0] = read_scalar(id, { macos_hal::SELECTOR_VOLUME_SCALAR, scope, macos_hal::ELEMENT_MAIN })!;
		return main;
	}
	sz channels = 0;
	if (macos_hal::has_property(id, { macos_hal::SELECTOR_VOLUME_SCALAR, scope, macos_hal::ELEMENT_LEFT })) channels++;
	if (macos_hal::has_property(id, { macos_hal::SELECTOR_VOLUME_SCALAR, scope, macos_hal::ELEMENT_RIGHT })) channels++;
	Gain[] gains = alloc::new_array(allocator, Gain, channels);
	sz at        = 0;
	if (macos_hal::has_property(id, { macos_hal::SELECTOR_VOLUME_SCALAR, scope, macos_hal::ELEMENT_LEFT }))
	{
		gains[at++] = read_scalar(id, { macos_hal::SELECTOR_VOLUME_SCALAR, scope, macos_hal::ELEMENT_LEFT })!;
	}
	if (macos_hal::has_property(id, { macos_hal::SELECTOR_VOLUME_SCALAR, scope, macos_hal::ELEMENT_RIGHT }))
	{
		gains[at++] = read_scalar(id, { macos_hal::SELECTOR_VOLUME_SCALAR, scope, macos_hal::ELEMENT_RIGHT })!;
	}
	return gains;
}

// One volume scalar, a Float32 clamped to the 0..1 range the HAL uses.
fn Gain? read_scalar(macos_hal::ObjectId id, macos_hal::PropertyAddress address) @private
{
	float value = 0.0f;
	macos_hal::read_property(id, address, &value, float::size)!;
	return unit::gain(value, 1.0f);
}

// The device as the model shows it in one flow.
fn Device device_of(Allocator allocator, HalDevice hal, Flow flow, bool is_default) @private
{
	Device device;
	device.id = hal.uid.copy(allocator);
	device.name = (hal.name.len > 0 ? hal.name : hal.uid).copy(allocator);
	device.flow = flow;
	device.form_factor = form_factor_of(hal.transport);
	device.bus = bus_of(hal.transport);
	device.is_default = is_default;
	device.volume = channel_volumes(allocator, hal.id, flow) ?? { };
	device.level = volume::loudest(device.volume).nominal();
	device.volume_is_hardware = macos_hal::has_property(
		hal.id,
		{ macos_hal::SELECTOR_VOLUME_SCALAR, scope_of(flow), macos_hal::ELEMENT_MAIN }
	) || macos_hal::has_property(
		hal.id,
		{ macos_hal::SELECTOR_VOLUME_SCALAR, scope_of(flow), macos_hal::ELEMENT_LEFT }
	);
	if (device.volume.len == 2) device.balance = maybe::value(
		volume::stereo_balance((float)device.volume[0], (float)device.volume[1])
	);
	if (macos_hal::has_property(hal.id, { macos_hal::SELECTOR_MUTE, scope_of(flow), macos_hal::ELEMENT_MAIN }))
	{
		device.muted = (macos_hal::read_u32(
			hal.id,
			{ macos_hal::SELECTOR_MUTE, scope_of(flow), macos_hal::ELEMENT_MAIN }
		) ?? 0) != 0;
	}
	return device;
}


<* The output and input devices of the state, and the default of each flow. *>
fn void devices_into(
	Allocator allocator,
	HalDevice[] hal,
	macos_hal::ObjectId default_output,
	macos_hal::ObjectId default_input,
	State* state
)
{
	sz outputs = 0;
	sz inputs  = 0;
	foreach (&d : hal)
	{
		if (d.has_output) outputs++;
		if (d.has_input) inputs++;
	}
	state.outputs = alloc::new_array(allocator, Device, outputs);
	state.inputs = alloc::new_array(allocator, Device, inputs);
	sz o = 0;
	sz i = 0;
	foreach (&d : hal)
	{
		if (d.has_output) state.outputs[o++] = device_of(allocator, *d, Flow.OUTPUT, d.id == default_output);
		if (d.has_input) state.inputs[i++] = device_of(allocator, *d, Flow.INPUT, d.id == default_input);
	}
	state.default_output = uid_of(hal, default_output).copy(allocator);
	state.default_input = uid_of(hal, default_input).copy(allocator);
}

// The uid of the device with `id`, or "" when none has it.
fn String uid_of(HalDevice[] devices, macos_hal::ObjectId id) @private
{
	foreach (&d : devices)
	{
		if (d.id == id) return d.uid;
	}
	return "";
}