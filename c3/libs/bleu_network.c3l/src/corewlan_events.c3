// CoreWLAN events: a delegate object that CoreWLAN calls on its own threads.
//
// The callbacks do one thing: they post a refresh to the service's mailbox.
// The mailbox is thread-safe and the worker reads the state, so no callback
// touches the service state or calls back into CoreWLAN.
//
// Selectors and encodings: CWWiFiClient.h via objc2-core-wlan 0.3.0
// (src/generated/CWWiFiClient.rs lines 22-150: the delegate methods, and
// CWEventType in CoreWLANTypes.rs 613-636). Registration: startMonitoringEventWithType:error:
// (CWWiFiClient.rs 267). The class is created with objc's ClassBuilder, as in
// bleu::objc (class.c3). Not run on macOS (see corewlan.c3).
module bleu::network::corewlan @feat(DARWIN) @link("CoreWLAN.framework");
import bleu::objc, bleu::rt::mailbox, bleu::network;

<* The CWEventType values the backend listens to (CoreWLANTypes.rs 613-636). *>
const long[7] EVENT_TYPES = {
	1, // PowerDidChange
	2, // SSIDDidChange
	3, // BSSIDDidChange
	5, // LinkDidChange
	6, // LinkQualityDidChange
	7, // ModeDidChange
	8, // ScanCacheUpdated
};

<* Ask the worker to refresh: the only thing a callback does. *>
fn void post_refresh(ObjId self) @local
{
	Mailbox{Command}* box = (Mailbox{Command}*)objc::context_of(self);
	if (box == null) return;
	// A full queue already holds a refresh, so a refused post changes nothing.
	if (catch err = box.post({ .kind = REFRESH })) {}
}

// powerStateDidChangeForWiFiInterfaceWithName:, ssidDidChange..., bssidDidChange..., linkDidChange..., modeDidChange..., scanCacheUpdatedForWiFiInterfaceWithName:
fn void on_interface_change(ObjId self, ObjSel selector, ObjId interface_name)
{
	post_refresh(self);
}

// linkQualityDidChangeForWiFiInterfaceWithName:rssi:transmitRate:
fn void on_link_quality(ObjId self, ObjSel selector, ObjId interface_name, long rssi, double transmit_rate)
{
	post_refresh(self);
}

// clientConnectionInterrupted, clientConnectionInvalidated: the framework's daemon went away or came back.
fn void on_client_state(ObjId self, ObjSel selector)
{
	post_refresh(self);
}

<*
 Register the delegate class (once per process), make an instance that posts
 to `box`, make it the client's delegate, and start monitoring each event.
 Returns the delegate, which the caller passes to `uninstall_delegate`.
*>
fn objc::Obj install_delegate(Mailbox{Command}* box)
{
	ObjClass cls = objc::class_named(DELEGATE_CLASS);
	if (cls == null)
	{
		// The class is new in this process; a failure here means the Objective-C runtime is broken.
		ClassBuilder builder = objc::begin_class(objc::class_named("NSObject"), DELEGATE_CLASS)!!;
		builder.add_context_ivar()!!;
		builder.method("powerStateDidChangeForWiFiInterfaceWithName:", (void*)&on_interface_change, "v@:@")!!;
		builder.method("ssidDidChangeForWiFiInterfaceWithName:", (void*)&on_interface_change, "v@:@")!!;
		builder.method("bssidDidChangeForWiFiInterfaceWithName:", (void*)&on_interface_change, "v@:@")!!;
		builder.method("countryCodeDidChangeForWiFiInterfaceWithName:", (void*)&on_interface_change, "v@:@")!!;
		builder.method("linkDidChangeForWiFiInterfaceWithName:", (void*)&on_interface_change, "v@:@")!!;
		builder.method("linkQualityDidChangeForWiFiInterfaceWithName:rssi:transmitRate:", (void*)&on_link_quality, "v@:@qd")!!;
		builder.method("modeDidChangeForWiFiInterfaceWithName:", (void*)&on_interface_change, "v@:@")!!;
		builder.method("scanCacheUpdatedForWiFiInterfaceWithName:", (void*)&on_interface_change, "v@:@")!!;
		builder.method("clientConnectionInterrupted", (void*)&on_client_state, "v@:")!!;
		builder.method("clientConnectionInvalidated", (void*)&on_client_state, "v@:")!!;
		cls = builder.finish();
	}
	objc::Obj delegate = objc::adopt(cls.send(ObjId, "new"));
	objc::set_context(delegate.ptr, box);
	objc::Obj client = objc::borrow(objc::class_named("CWWiFiClient").send(ObjId, "sharedWiFiClient"));
	defer client.close();
	client.send_void("setDelegate:", delegate.ptr);
	foreach (type : EVENT_TYPES)
	{
		ObjId err = null;
		// A refused registration means that event is not delivered; the poll tick still refreshes the state.
		if (!client.send_bool("startMonitoringEventWithType:error:", type, &err)) continue;
	}
	return delegate;
}

<* Stop monitoring, detach the delegate and release it. Runs on the worker. *>
fn void uninstall_delegate(objc::Obj delegate)
{
	objc::Obj client = objc::borrow(objc::class_named("CWWiFiClient").send(ObjId, "sharedWiFiClient"));
	defer client.close();
	ObjId err = null;
	client.send_bool("stopMonitoringAllEventsAndReturnError:", &err);
	client.send_void("setDelegate:", (ObjId)null);
	delegate.close();
}
