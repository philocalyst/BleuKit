<*
 IOKit registry access for Bleu: services, their properties, matching
 iterators, and notifications delivered on a run loop.

 Ownership: every `io_object_t` (service, iterator, notification) is released by
 its wrapper's `close()`. CoreFoundation dictionaries returned as "Create" results
 are wrapped in `cf::Ref`. Matching dictionaries are consumed by the API that
 takes them, exactly as IOKitLib.h documents, so this module never releases them.

 Sources: IOKit `IOKitLib.h` (IOServiceGetMatchingServices, IOServiceAddMatchingNotification,
 IOServiceAddInterestNotification, IORegistryEntryCreateCFProperties,
 IORegistryEntrySearchCFProperty, IONotificationPortCreate, IOServiceClose,
 IOObjectRelease) and `IOKitKeys.h` (kIOServicePlane, kIOGeneralInterest,
 kIOFirstMatchNotification, kIOTerminatedNotification) from apple-oss-distributions/IOKitUser
 and xnu. Second source: io-kit-sys 0.4.1 `src/lib.rs` (the same prototypes) and `src/keys.rs`.
 `io_object_t` is `mach_port_t`, which is `unsigned int` (mach2 `port.rs`).
*>
module bleu::iokit @feat(DARWIN) @link("IOKit.framework");
import bleu::error, bleu::mach, bleu::cf;

<*
 `io_object_t`, `io_service_t`, `io_iterator_t`, `io_registry_entry_t`, `io_connect_t`: all `mach_port_t` (unsigned
 int).
*>
alias IoObject = uint;

<* `kIOMainPortDefault`: the default main port (IOKitLib.h). *>
extern const uint K_IO_MAIN_PORT_DEFAULT @cname("kIOMainPortDefault");

<* `kIOServicePlane` (IOKitKeys.h): the plane services live in. *>
const ZString IO_SERVICE_PLANE             = "IOService";
<* `kIOGeneralInterest` (IOKitKeys.h): the interest type for service state changes. *>
const ZString IO_GENERAL_INTEREST          = "IOGeneralInterest";
<* `kIOFirstMatchNotification` (IOKitKeys.h): first time a matching service is ready. *>
const ZString IO_FIRST_MATCH_NOTIFICATION  = "IOServiceFirstMatch";
<* `kIOTerminatedNotification` (IOKitKeys.h): a matching service is terminated. *>
const ZString IO_TERMINATED_NOTIFICATION   = "IOServiceTerminate";
<* `kIORegistryIterateRecursively` (IOKitLib.h): search the children too. *>
const uint IO_REGISTRY_ITERATE_RECURSIVELY = 1;

extern fn CFTypeRef io_service_matching(ZString name) @cname("IOServiceMatching");
extern fn int io_service_get_matching_services(
	uint main_port,
	CFTypeRef matching,
	IoObject* iterator
) @cname("IOServiceGetMatchingServices");
extern fn IoObject io_iterator_next(IoObject iterator) @cname("IOIteratorNext");
extern fn int io_object_release(IoObject object) @cname("IOObjectRelease");
extern fn int io_service_close(IoObject connect) @cname("IOServiceClose");
extern fn int io_registry_entry_create_cf_properties(
	IoObject entry,
	CFTypeRef* properties,
	CFTypeRef allocator,
	uint options
) @cname("IORegistryEntryCreateCFProperties");
extern fn CFTypeRef io_registry_entry_search_cf_property(
	IoObject entry,
	ZString plane,
	CFTypeRef key,
	CFTypeRef allocator,
	uint options
) @cname("IORegistryEntrySearchCFProperty");
extern fn void* io_notification_port_create(uint main_port) @cname("IONotificationPortCreate");
extern fn void io_notification_port_destroy(void* port) @cname("IONotificationPortDestroy");
extern fn void* io_notification_port_get_run_loop_source(void* port) @cname("IONotificationPortGetRunLoopSource");
extern fn int io_service_add_matching_notification(
	void* port,
	ZString type,
	CFTypeRef matching,
	MatchingCallback callback,
	void* refcon,
	IoObject* notification
) @cname("IOServiceAddMatchingNotification");
extern fn int io_service_add_interest_notification(
	void* port,
	IoObject service,
	ZString type,
	InterestCallback callback,
	void* refcon,
	IoObject* notification
) @cname("IOServiceAddInterestNotification");

<*
 Called on the notification port's run loop when a matching service appears or
 is terminated. `iterator` yields the services; iterate it to the end to re-arm the notification.
*>
alias MatchingCallback = fn void(void* refcon, IoObject iterator);

<* Called on the notification port's run loop for a service's state change (`IOServiceInterestCallback`). *>
alias InterestCallback = fn void(void* refcon, IoObject service, uint message, void* argument);

<* An IORegistry service (`io_service_t`), owned until `close`. *>
struct Service
{
	IoObject handle;
}

<* Release the service object. Idempotent. *>
fn void Service.close(&self)
{
	if (self.handle) io_object_release(self.handle);
	self.handle = 0;
}

<*
 The service's full property dictionary, as an owned CoreFoundation dictionary.

 @return? error::UNAVAILABLE : "when the service is gone"
 @return? error::BACKEND_FAILURE : "when the registry refuses to copy the properties"
*>
fn cf::Ref? Service.properties(self)
{
	if (!self.handle) return error::raise(error::UNAVAILABLE, error::Domain.MACH, 0, "service is closed")~;
	CFTypeRef properties = null;
	int result           = io_registry_entry_create_cf_properties(self.handle, &properties, null, 0);
	if (result != 0) return mach::raise_code(result, "IORegistryEntryCreateCFProperties")~;
	return cf::adopt(properties);
}

<*
 A property by name, searched up the IOService plane from this service (the
 registry's `kIORegistryIterateRecursively` option). Returns an owned value,
 or NOT_FOUND when no service on the path has the key.

 @return? NOT_FOUND : "when no service has the property"
*>
fn cf::Ref? Service.search_property(self, ZString key)
{
	cf::Ref name = cf::from_string(key.str_view());
	defer name.close();
	CFTypeRef value = io_registry_entry_search_cf_property(
		self.handle,
		IO_SERVICE_PLANE,
		name.ptr,
		null,
		IO_REGISTRY_ITERATE_RECURSIVELY
	);
	if (!value) return NOT_FOUND~;
	return cf::adopt(value);
}

<* An iterator over services, owned until `close`. *>
struct ServiceIterator
{
	IoObject handle;
}

<*
 Every registered service of class `class_name` (and its subclasses), as an iterator.

 @return? error::BACKEND_FAILURE : "when the registry refuses the match"
*>
fn ServiceIterator? services_matching(ZString class_name)
{
	IoObject iterator = 0;
	int result = io_service_get_matching_services(K_IO_MAIN_PORT_DEFAULT, io_service_matching(class_name), &iterator);
	if (result != 0) return mach::raise_code(result, "IOServiceGetMatchingServices")~;
	return { .handle = iterator };
}

<*
 The next service, owned by the caller. `NO_MORE_ELEMENT` when the iteration is over.
*>
fn Service? ServiceIterator.next(self)
{
	IoObject handle = io_iterator_next(self.handle);
	if (!handle) return NO_MORE_ELEMENT~;
	return { .handle = handle };
}

<* Release the iterator. Idempotent. *>
fn void ServiceIterator.close(&self)
{
	if (self.handle) io_object_release(self.handle);
	self.handle = 0;
}

<* A notification port: IOKit posts to it, and it is driven by a run loop. *>
struct NotificationPort
{
	void* port;
}

<*
 Create a notification port. Attach `source()` to a run loop to receive events.

 @return? error::BACKEND_FAILURE : "when IOKit cannot create the port"
*>
fn NotificationPort? create_notification_port()
{
	void* port = io_notification_port_create(K_IO_MAIN_PORT_DEFAULT);
	if (!port) return error::raise(error::BACKEND_FAILURE, error::Domain.MACH, 0, "IONotificationPortCreate failed")~;
	return { .port = port };
}

<* The run-loop source for the port (`CFRunLoopSourceRef`). Owned by the port; do not release. *>
fn void* NotificationPort.source(self) => io_notification_port_get_run_loop_source(self.port);

<* Destroy the port. The run-loop source must already be removed from every loop. Idempotent. *>
fn void NotificationPort.close(&self)
{
	if (self.port) io_notification_port_destroy(self.port);
	self.port = null;
}

<* An armed matching notification. Owned until `close`. *>
struct MatchingNotification
{
	IoObject handle;
}

<*
 Call `callback` when a service of `class_name` matches `notification_type`
 (`IO_FIRST_MATCH_NOTIFICATION` or `IO_TERMINATED_NOTIFICATION`). The notification
 is armed when the returned iterator is drained, so `callback` should drain it.

 @return? error::BACKEND_FAILURE : "when the registry refuses the notification"
*>
fn MatchingNotification? on_matching(
	NotificationPort port,
	ZString notification_type,
	ZString class_name,
	MatchingCallback callback,
	void* refcon
)
{
	IoObject handle = 0;
	int result = io_service_add_matching_notification(
		port.port,
		notification_type,
		io_service_matching(class_name),
		callback,
		refcon,
		&handle
	);
	if (result != 0) return mach::raise_code(result, "IOServiceAddMatchingNotification")~;
	return { .handle = handle };
}

<* Remove a matching notification. Idempotent. *>
fn void MatchingNotification.close(&self)
{
	if (self.handle) io_object_release(self.handle);
	self.handle = 0;
}

<* An armed interest notification on one service. Owned until `close`. *>
struct InterestNotification
{
	IoObject handle;
}

<*
 Call `callback` for every state change of `service` (power, termination,
 busy-state). The service must stay open while the notification is armed.

 @return? error::BACKEND_FAILURE : "when the registry refuses the notification"
*>
fn InterestNotification? on_service_change(
	NotificationPort port,
	Service service,
	InterestCallback callback,
	void* refcon
)
{
	IoObject handle = 0;
	int result = io_service_add_interest_notification(
		port.port,
		service.handle,
		IO_GENERAL_INTEREST,
		callback,
		refcon,
		&handle
	);
	if (result != 0) return mach::raise_code(result, "IOServiceAddInterestNotification")~;
	return { .handle = handle };
}

<* Remove an interest notification. Idempotent. *>
fn void InterestNotification.close(&self)
{
	if (self.handle) io_object_release(self.handle);
	self.handle = 0;
}