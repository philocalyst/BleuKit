<*
 The macOS backend: Text Input Sources (HIToolbox), the keyboard layouts the user has enabled.

 Binding sources (HIToolbox TextInputSources.h, MacOSX SDK, read 2026-10-20 from the phracker/MacOSX-SDKs
 mirror, path System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/
 Headers/TextInputSources.h):
   TISCreateInputSourceList(CFDictionaryRef properties, Boolean includeAllInstalled) -> CFArrayRef
   TISCopyCurrentKeyboardInputSource(void) -> TISInputSourceRef (a Copy: owned)
   TISGetInputSourceProperty(TISInputSourceRef, CFStringRef key) -> void* (a Get: not owned)
   TISSelectInputSource(TISInputSourceRef) -> OSStatus, paramErr when the source is not selectable
   constants TIS_PROPERTY_INPUT_SOURCE_ID, TIS_PROPERTY_LOCALIZED_NAME, TIS_PROPERTY_INPUT_SOURCE_LANGUAGES,
   TIS_PROPERTY_INPUT_SOURCE_IS_SELECT_CAPABLE, TIS_PROPERTY_INPUT_SOURCE_TYPE, TIS_TYPE_KEYBOARD_LAYOUT,
   TIS_NOTIFY_SELECTED_KEYBOARD_INPUT_SOURCE_CHANGED (a CF distributed notification name).
 Second source: Firefox widget/cocoa/TextInputHandler.mm (mozilla/gecko-dev, read 2026-10-20) calls
 TISCreateInputSourceList with a filter on TIS_PROPERTY_INPUT_SOURCE_TYPE = TIS_TYPE_KEYBOARD_LAYOUT, and observes
 TIS_NOTIFY_SELECTED_KEYBOARD_INPUT_SOURCE_CHANGED on CFNotificationCenterGetDistributedCenter().
 CFNotificationCenter signatures and CFNotificationSuspensionBehaviorDeliverImmediately = 4: core-foundation-sys
 0.8.7 src/notification_center.rs (read 2026-10-20).

 Not verified on a Mac: that TIS calls may be made from a worker thread (Firefox makes them on its main thread),
 and that the distributed notification reaches an observer registered on this worker thread, which runs no
 run loop. The 1 s poll re-reads the sources regardless, so a missed notification costs at most one poll interval.
 The notification callback only enqueues a REFRESH; it never reads the sources or publishes.
*>
module bleu::input::macos_tis @feat(DARWIN) @link("Carbon.framework");
import bleu::availability, bleu::cf, bleu::error, bleu::input, bleu::input::names, bleu::observe, bleu::operation, bleu::rt::poller, bleu::rt::worker, bleu::service;

// Enabled sources only: TISCreateInputSourceList's includeAllInstalled is false (TextInputSources.h).
const bool ENABLED_ONLY = false;
// OSStatus noErr.
const int NO_ERROR = 0;
// Commands the worker takes in one pass.
const usz COMMAND_BATCH = 8;
// CFNotificationSuspensionBehaviorDeliverImmediately (core-foundation-sys notification_center.rs).
const cf::CFIndex DELIVER_IMMEDIATELY = 4;

extern fn CFTypeRef tis_create_input_source_list(CFTypeRef properties, bool include_all_installed) @cname("TISCreateInputSourceList");
extern fn CFTypeRef tis_copy_current_keyboard_input_source() @cname("TISCopyCurrentKeyboardInputSource");
extern fn CFTypeRef tis_get_input_source_property(CFTypeRef source, CFTypeRef key) @cname("TISGetInputSourceProperty");
extern fn int tis_select_input_source(CFTypeRef source) @cname("TISSelectInputSource");

extern const CFTypeRef TIS_PROPERTY_INPUT_SOURCE_ID @cname("TIS_PROPERTY_INPUT_SOURCE_ID");
extern const CFTypeRef TIS_PROPERTY_LOCALIZED_NAME @cname("TIS_PROPERTY_LOCALIZED_NAME");
extern const CFTypeRef TIS_PROPERTY_INPUT_SOURCE_LANGUAGES @cname("TIS_PROPERTY_INPUT_SOURCE_LANGUAGES");
extern const CFTypeRef TIS_PROPERTY_INPUT_SOURCE_IS_SELECT_CAPABLE @cname("TIS_PROPERTY_INPUT_SOURCE_IS_SELECT_CAPABLE");
extern const CFTypeRef TIS_PROPERTY_INPUT_SOURCE_TYPE @cname("TIS_PROPERTY_INPUT_SOURCE_TYPE");
extern const CFTypeRef TIS_TYPE_KEYBOARD_LAYOUT @cname("TIS_TYPE_KEYBOARD_LAYOUT");
extern const CFTypeRef TIS_NOTIFY_SELECTED_KEYBOARD_INPUT_SOURCE_CHANGED @cname("TIS_NOTIFY_SELECTED_KEYBOARD_INPUT_SOURCE_CHANGED");

extern fn CFTypeRef cf_dictionary_create(CFTypeRef allocator, CFTypeRef* keys, CFTypeRef* values, cf::CFIndex count, void* key_callbacks, void* value_callbacks) @cname("CFDictionaryCreate");
extern fn CFTypeRef cf_notification_center_distributed() @cname("CFNotificationCenterGetDistributedCenter");
extern fn void cf_notification_center_add_observer(CFTypeRef center, void* observer, NotificationCallback callback, CFTypeRef name, CFTypeRef object, cf::CFIndex behavior) @cname("CFNotificationCenterAddObserver");
extern fn void cf_notification_center_remove_observer(CFTypeRef center, void* observer, CFTypeRef name, CFTypeRef object) @cname("CFNotificationCenterRemoveObserver");

// CFNotificationCallback: (center, observer, name, object, userInfo).
alias NotificationCallback = fn void(CFTypeRef center, void* observer, CFTypeRef name, void* object, CFTypeRef info);

<* The backend's state. `host` is set by `run`; the notification callback posts through it. *>
struct TisBackend
{
	Allocator allocator;
	Duration poll;
	Host{Command}* host;
}

const Driver DRIVER = {
	.info = { "tis", "Text Input Sources (HIToolbox, Carbon.framework)", 10 },
	.id = Backend.TIS,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// Text Input Sources exists on every macOS this targets: a plain check, nothing to open.
fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.set(
		Cap.EVENTS,
		availability::no(
			availability::Reason.DEGRADED,
			"Notifications need a run loop on the worker thread; the state is also read at every poll interval"
		)
	);
	TisBackend* backend = alloc::new(allocator, TisBackend, { .allocator = allocator, .poll = options.poll });
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

// The notification callback: enqueue a refresh and return. A full queue already holds one.
fn void on_selection_changed(CFTypeRef center, void* observer, CFTypeRef name, void* object, CFTypeRef info)
{
	TisBackend* backend = (TisBackend*)observer;
	Command command = { .kind = CommandKind.REFRESH };
	if (catch backend.host.mailbox().post(command))
	{
		// The queue is full of commands, which trigger a read as well.
	}
}

// The last path component of a source id ("US" in "com.apple.keylayout.US"), as its short code.
fn String short_code_of_id(String id, Allocator allocator) @private
{
	sz start = 0;
	for (sz i = 0; i < id.len; i++)
	{
		if (id[i] == '.') start = i + 1;
	}
	return names::short_code_of(id[start:id.len - start], allocator);
}

// A dictionary { TIS_PROPERTY_INPUT_SOURCE_TYPE: TIS_TYPE_KEYBOARD_LAYOUT }, owned.
fn cf::Ref keyboard_layout_filter() @private
{
	CFTypeRef[1] keys   = { TIS_PROPERTY_INPUT_SOURCE_TYPE };
	CFTypeRef[1] values = { TIS_TYPE_KEYBOARD_LAYOUT };
	return cf::adopt(cf_dictionary_create(null, &keys[0], &values[0], 1, null, null));
}

// The source's string property, borrowed from the source: null when absent.
fn CFTypeRef string_property(CFTypeRef source, CFTypeRef key) @private => tis_get_input_source_property(source, key);

// Whether the source can be selected with TISSelectInputSource. Absent means not selectable.
fn bool selectable(CFTypeRef source) @private
{
	CFTypeRef flag = tis_get_input_source_property(source, TIS_PROPERTY_INPUT_SOURCE_IS_SELECT_CAPABLE);
	return flag != null && cf::cf_boolean_get_value(flag);
}

<*
 The layout a source describes: its id, its localized name, its first language as the tag, and a short code
 from its id. All text is allocated in `allocator`.

 @return? error::BACKEND_FAILURE : "when the source has no id"
*>
fn Layout? layout_of(CFTypeRef source, Allocator allocator) @private
{
	String id = cf::string_value(string_property(source, TIS_PROPERTY_INPUT_SOURCE_ID), allocator)!;
	String name = cf::string_value(string_property(source, TIS_PROPERTY_LOCALIZED_NAME), allocator) ?? id;
	String language = "";
	CFTypeRef languages = string_property(source, TIS_PROPERTY_INPUT_SOURCE_LANGUAGES);
	if (cf::array_count(languages) > 0)
	{
		language = cf::string_value(cf::array_at(languages, 0), allocator) ?? "";
	}
	return {
		.id = id,
		.name = name,
		.short_code = short_code_of_id(id, allocator),
		.language = language,
		.variant = "".copy(allocator),
	};
}

<*
 The enabled keyboard layouts and the active one. Text is allocated in `allocator`.

 @return? error::BACKEND_FAILURE : "when TISCreateInputSourceList returns nothing"
*>
fn State? read_state(Allocator allocator) @private
{
	cf::Ref filter = keyboard_layout_filter();
	defer filter.close();
	cf::Ref list = cf::adopt(tis_create_input_source_list(filter.ptr, ENABLED_ONLY));
	defer list.close();
	if (list.is_nil()) return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "TISCreateInputSourceList returned no list")~;
	sz total = cf::array_count(list.ptr);
	sz kept = 0;
	for (sz i = 0; i < total; i++)
	{
		if (selectable(cf::array_at(list.ptr, i))) kept++;
	}
	Layout[] layouts = alloc::new_array(allocator, Layout, kept);
	sz out = 0;
	for (sz i = 0; i < total; i++)
	{
		CFTypeRef source = cf::array_at(list.ptr, i);
		if (!selectable(source)) continue;
		if (try layout = layout_of(source, allocator)) layouts[out++] = layout;
	}
	Maybe{uint} current = { };
	cf::Ref active = cf::adopt(tis_copy_current_keyboard_input_source());
	defer active.close();
	if (!active.is_nil())
	{
		String active_id = cf::string_value(string_property(active.ptr, TIS_PROPERTY_INPUT_SOURCE_ID), allocator) ?? "";
		sz index = index_of(layouts[0:out], active_id);
		if (index >= 0) current = { .value = (uint)index, .has_value = true };
	}
	return { .layouts = layouts[0:out], .current = current, .can_switch = can_switch_now(true, out) };
}

// Publish the sources now. An unreadable source list is an empty state.
fn void refresh(TisBackend* backend, InputHub* hub) @private
{
	Snapshot{State}* snapshot = hub.begin();
	if (try state = read_state(snapshot.allocator()))
	{
		snapshot.value = state;
	}
	else
	{
		snapshot.value = { };
	}
	publish_state(hub, snapshot);
}

<*
 Select the enabled source with `id`. TISSelectInputSource needs the source itself, so the list is read again and
 searched; the source is found in the same list that is released after the call.

 @return? NOT_FOUND : "No enabled keyboard layout has that id"
 @return? error::BACKEND_FAILURE : "TISSelectInputSource refused it (the status is an OSStatus)"
*>
fn void? select(String id) @private
{
	cf::Ref filter = keyboard_layout_filter();
	defer filter.close();
	cf::Ref list = cf::adopt(tis_create_input_source_list(filter.ptr, ENABLED_ONLY));
	defer list.close();
	if (list.is_nil()) return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "TISCreateInputSourceList returned no list")~;
	sz total = cf::array_count(list.ptr);
	for (sz i = 0; i < total; i++)
	{
		CFTypeRef source = cf::array_at(list.ptr, i);
		if (!selectable(source)) continue;
		bool matched = false;
		int status = NO_ERROR;
		@pool()
		{
			String source_id = cf::string_value(string_property(source, TIS_PROPERTY_INPUT_SOURCE_ID), tmem) ?? "";
			if (source_id == id)
			{
				matched = true;
				status = tis_select_input_source(source);
			}
		};
		if (matched)
		{
			if (status != NO_ERROR) return error::raise(error::BACKEND_FAILURE, error::Domain.MACH, status, "TISSelectInputSource returned %d", status)~;
			return;
		}
	}
	return NOT_FOUND~;
}

fn void run(void* state, InputHub* hub, Host{Command}* host)
{
	TisBackend* backend = (TisBackend*)state;
	backend.host = host;
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	CFTypeRef center = cf_notification_center_distributed();
	cf_notification_center_add_observer(center, backend, &on_selection_changed, TIS_NOTIFY_SELECTED_KEYBOARD_INPUT_SOURCE_CHANGED, null, DELIVER_IMMEDIATELY);
	defer cf_notification_center_remove_observer(center, backend, TIS_NOTIFY_SELECTED_KEYBOARD_INPUT_SOURCE_CHANGED, null);
	refresh(backend, hub);
	Command[COMMAND_BATCH] commands;
	while (!host.stopping())
	{
		// A timeout is normal: the sources are read again at each poll interval.
		if (catch poller.wait(backend.poll))
		{
			// Nothing ready.
		}
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++)
		{
			if (commands[i].kind != CommandKind.SWITCH_TO) continue;
			SwitchOperation* operation = commands[i].operation;
			if (catch err = select(commands[i].id_text()))
			{
				fail_switch(operation, err);
			}
			else
			{
				succeed_switch(operation, SwitchOutcome.ACKNOWLEDGED);
			}
		}
		refresh(backend, hub);
	}
}
