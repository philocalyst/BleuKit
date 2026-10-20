<*
 The two Wayland data-control protocols, behind one set of calls. ext-data-control-v1 is
 preferred; wlr-data-control-unstable-v1 is the wlroots fallback. They have the same
 requests and events with different generated names, so each call here dispatches on the
 protocol in use, and each listener forwards to the common path in `linux_wl_session.c3`.

 Sources: wayland-protocols staging/ext-data-control/ext-data-control-v1.xml and wlr-protocols
 unstable/wlr-data-control-unstable-v1.xml (both read in docs/research/session_windows_input.md),
 and the generated bindings in bleu_wl (`src/proto/`).
*>
module bleu::clipboard::linux_wl @feat(LINUX);
import bleu::clipboard, bleu::rt, bleu::wl::display, bleu::wl::proto::wayland, bleu::wl::proto::ext_data_control, bleu::wl::proto::wlr_data_control;

<* Which data-control protocol a session bound. *>
enum DataControl : char
{
	EXT, // ext-data-control-v1
	WLR, // wlr-data-control-unstable-v1
}

<* Interface names, as the registry advertises them. *>
const String EXT_MANAGER_NAME = "ext_data_control_manager_v1";
const String WLR_MANAGER_NAME = "zwlr_data_control_manager_v1";

<*
 Primary selection is reported and set through the device of both protocols from version 2
 (ext-data-control is version 1 and always has it; wlr-data-control gained it at version 2).
*>
const uint WLR_PRIMARY_VERSION = 2;

// ---- Requests ----------------------------------------------------------------------

<* The device of `seat` from `manager`. The device's events go to `listener`. *>
fn display::Proxy*? proto_get_device(DataControl kind, display::Proxy* manager, display::Proxy* seat)
{
	if (kind == EXT)
	{
		ext_data_control::ExtDataControlManagerV1* typed = (ext_data_control::ExtDataControlManagerV1*)manager;
		ext_data_control::ExtDataControlDeviceV1* device = typed.get_data_device((wayland::WlSeat*)seat)!;
		return (display::Proxy*)device;
	}
	wlr_data_control::ZwlrDataControlManagerV1* typed = (wlr_data_control::ZwlrDataControlManagerV1*)manager;
	wlr_data_control::ZwlrDataControlDeviceV1* device = typed.get_data_device((wayland::WlSeat*)seat)!;
	return (display::Proxy*)device;
}

<* A new source object from `manager`. *>
fn display::Proxy*? proto_create_source(DataControl kind, display::Proxy* manager)
{
	if (kind == EXT)
	{
		ext_data_control::ExtDataControlManagerV1* typed = (ext_data_control::ExtDataControlManagerV1*)manager;
		ext_data_control::ExtDataControlSourceV1* source = typed.create_data_source()!;
		return (display::Proxy*)source;
	}
	wlr_data_control::ZwlrDataControlManagerV1* typed = (wlr_data_control::ZwlrDataControlManagerV1*)manager;
	wlr_data_control::ZwlrDataControlSourceV1* source = typed.create_data_source()!;
	return (display::Proxy*)source;
}

<* Advertise `mime` on a source, before it is set as a selection. *>
fn void? proto_source_offer(DataControl kind, display::Proxy* source, String mime)
{
	if (kind == EXT) return ((ext_data_control::ExtDataControlSourceV1*)source).offer(mime);
	return ((wlr_data_control::ZwlrDataControlSourceV1*)source).offer(mime);
}

<* Make `source` (or nothing, for null) the clipboard or the primary selection of `device`. *>
fn void? proto_set_selection(DataControl kind, display::Proxy* device, display::Proxy* source, Slot slot)
{
	display::Proxy* offered = source;
	if (kind == EXT)
	{
		ext_data_control::ExtDataControlDeviceV1* typed        = (ext_data_control::ExtDataControlDeviceV1*)device;
		ext_data_control::ExtDataControlSourceV1* typed_source = (ext_data_control::ExtDataControlSourceV1*)offered;
		if (slot == Slot.PRIMARY) return typed.set_primary_selection(typed_source);
		return typed.set_selection(typed_source);
	}
	wlr_data_control::ZwlrDataControlDeviceV1* typed        = (wlr_data_control::ZwlrDataControlDeviceV1*)device;
	wlr_data_control::ZwlrDataControlSourceV1* typed_source = (wlr_data_control::ZwlrDataControlSourceV1*)offered;
	if (slot == Slot.PRIMARY) return typed.set_primary_selection(typed_source);
	return typed.set_selection(typed_source);
}

<*
 Ask the owner of `offer` to write `mime` into `fd`. The caller keeps its own descriptor
 open until it has written the request out, then closes it.
*>
fn void? proto_receive(DataControl kind, display::Proxy* offer, String mime, rt::Native fd)
{
	if (kind == EXT) return ((ext_data_control::ExtDataControlOfferV1*)offer).receive(mime, fd);
	return ((wlr_data_control::ZwlrDataControlOfferV1*)offer).receive(mime, fd);
}

<* Destroy an offer object. Its events stop; the object is retired locally. *>
fn void? proto_destroy_offer(DataControl kind, display::Proxy* offer)
{
	if (kind == EXT) return ((ext_data_control::ExtDataControlOfferV1*)offer).destroy();
	return ((wlr_data_control::ZwlrDataControlOfferV1*)offer).destroy();
}

<* Destroy a source object. *>
fn void? proto_destroy_source(DataControl kind, display::Proxy* source)
{
	if (kind == EXT) return ((ext_data_control::ExtDataControlSourceV1*)source).destroy();
	return ((wlr_data_control::ZwlrDataControlSourceV1*)source).destroy();
}

<* Destroy a device object. *>
fn void? proto_destroy_device(DataControl kind, display::Proxy* device)
{
	if (kind == EXT) return ((ext_data_control::ExtDataControlDeviceV1*)device).destroy();
	return ((wlr_data_control::ZwlrDataControlDeviceV1*)device).destroy();
}

// ---- Listeners ---------------------------------------------------------------------
// Each listener receives typed pointers; the common path takes the proxies they share.

// Device forwarders ----------------------------------------------------------------

fn void ext_data_offer(
	void* context,
	ext_data_control::ExtDataControlDeviceV1* target,
	ext_data_control::ExtDataControlOfferV1* id
)
{
	device_data_offer((WlSession*)context, (display::Proxy*)id);
}

fn void ext_selection(
	void* context,
	ext_data_control::ExtDataControlDeviceV1* target,
	ext_data_control::ExtDataControlOfferV1* id
)
{
	device_selection((WlSession*)context, Slot.CLIPBOARD, (display::Proxy*)id);
}

fn void ext_primary_selection(
	void* context,
	ext_data_control::ExtDataControlDeviceV1* target,
	ext_data_control::ExtDataControlOfferV1* id
)
{
	device_selection((WlSession*)context, Slot.PRIMARY, (display::Proxy*)id);
}

fn void ext_finished(void* context, ext_data_control::ExtDataControlDeviceV1* target)
{
	device_finished((WlSession*)context);
}

fn void wlr_data_offer(
	void* context,
	wlr_data_control::ZwlrDataControlDeviceV1* target,
	wlr_data_control::ZwlrDataControlOfferV1* id
)
{
	device_data_offer((WlSession*)context, (display::Proxy*)id);
}

fn void wlr_selection(
	void* context,
	wlr_data_control::ZwlrDataControlDeviceV1* target,
	wlr_data_control::ZwlrDataControlOfferV1* id
)
{
	device_selection((WlSession*)context, Slot.CLIPBOARD, (display::Proxy*)id);
}

fn void wlr_primary_selection(
	void* context,
	wlr_data_control::ZwlrDataControlDeviceV1* target,
	wlr_data_control::ZwlrDataControlOfferV1* id
)
{
	device_selection((WlSession*)context, Slot.PRIMARY, (display::Proxy*)id);
}

fn void wlr_finished(void* context, wlr_data_control::ZwlrDataControlDeviceV1* target)
{
	device_finished((WlSession*)context);
}

// Offer and source forwarders -------------------------------------------------------

fn void ext_offer_mime(void* context, ext_data_control::ExtDataControlOfferV1* target, String mime_type)
{
	offer_mime((WlOffer*)context, mime_type);
}

fn void wlr_offer_mime(void* context, wlr_data_control::ZwlrDataControlOfferV1* target, String mime_type)
{
	offer_mime((WlOffer*)context, mime_type);
}

fn void ext_source_send(
	void* context,
	ext_data_control::ExtDataControlSourceV1* target,
	String mime_type,
	rt::Native fd
)
{
	source_send((WlSource*)context, mime_type, fd);
}

fn void ext_source_cancelled(void* context, ext_data_control::ExtDataControlSourceV1* target)
{
	source_cancelled((WlSource*)context);
}

fn void wlr_source_send(
	void* context,
	wlr_data_control::ZwlrDataControlSourceV1* target,
	String mime_type,
	rt::Native fd
)
{
	source_send((WlSource*)context, mime_type, fd);
}

fn void wlr_source_cancelled(void* context, wlr_data_control::ZwlrDataControlSourceV1* target)
{
	source_cancelled((WlSource*)context);
}

const ext_data_control::ExtDataControlDeviceV1Listener EXT_DEVICE_LISTENER = {
	.data_offer = &ext_data_offer,
	.selection = &ext_selection,
	.finished = &ext_finished,
	.primary_selection = &ext_primary_selection,
};

const wlr_data_control::ZwlrDataControlDeviceV1Listener WLR_DEVICE_LISTENER = {
	.data_offer = &wlr_data_offer,
	.selection = &wlr_selection,
	.finished = &wlr_finished,
	.primary_selection = &wlr_primary_selection,
};

const ext_data_control::ExtDataControlOfferV1Listener EXT_OFFER_LISTENER    = { .offer = &ext_offer_mime };
const wlr_data_control::ZwlrDataControlOfferV1Listener WLR_OFFER_LISTENER   = { .offer = &wlr_offer_mime };
const ext_data_control::ExtDataControlSourceV1Listener EXT_SOURCE_LISTENER  = {
	.send = &ext_source_send,
	.cancelled = &ext_source_cancelled
};
const wlr_data_control::ZwlrDataControlSourceV1Listener WLR_SOURCE_LISTENER = {
	.send = &wlr_source_send,
	.cancelled = &wlr_source_cancelled
};

<* Attach the device listener of `kind` to `device`, with `context` as the session. *>
fn void proto_listen_device(DataControl kind, display::Proxy* device, void* context)
{
	if (kind == EXT) return ((ext_data_control::ExtDataControlDeviceV1*)device).set_listener(
		&EXT_DEVICE_LISTENER,
		context
	);
	((wlr_data_control::ZwlrDataControlDeviceV1*)device).set_listener(&WLR_DEVICE_LISTENER, context);
}

<* Attach the offer listener of `kind` to `offer`. *>
fn void proto_listen_offer(DataControl kind, display::Proxy* offer, void* context)
{
	if (kind == EXT) return ((ext_data_control::ExtDataControlOfferV1*)offer).set_listener(
		&EXT_OFFER_LISTENER,
		context
	);
	((wlr_data_control::ZwlrDataControlOfferV1*)offer).set_listener(&WLR_OFFER_LISTENER, context);
}

<* Attach the source listener of `kind` to `source`. *>
fn void proto_listen_source(DataControl kind, display::Proxy* source, void* context)
{
	if (kind == EXT) return ((ext_data_control::ExtDataControlSourceV1*)source).set_listener(
		&EXT_SOURCE_LISTENER,
		context
	);
	((wlr_data_control::ZwlrDataControlSourceV1*)source).set_listener(&WLR_SOURCE_LISTENER, context);
}