<*
 The macOS backend: our own icon in the menu bar (NSStatusItem), with its menu.

 It cannot list other applications' menu-bar items: the only route is Accessibility (AXUIElement
 on SystemUIServer), which needs a permission and is not used, so `HOST` is UNSUPPORTED_OS.

 AppKit is main-thread only, so the status item is built by `create` and removed by `destroy`,
 which run on the thread that calls `open` and `close`: call them on the main thread. The menu's
 target is an Objective-C object whose action runs on the main thread and only posts a command
 to the worker's mailbox; the worker emits the event. A click that arrives after the service has
 closed is refused by the mailbox and dropped.

 Sources: Apple AppKit reference, NSStatusItem, NSStatusBar, NSMenu, NSMenuItem (developer.apple.com);
 the target-action and class-building pattern is bleu_objc's ClassBuilder, as bleu_network uses it.
*>
module bleu::tray::appkit @feat(DARWIN);
import std::time, std::os::darwin::objc, bleu::availability, bleu::error, bleu::objc, bleu::objc::foundation, bleu::rt::mailbox, bleu::rt::poller, bleu::rt::worker, bleu::service, bleu::tray, bleu::tray::convert, bleu::observe;

// The Objective-C class that receives the menu's actions, and the action's selector and type encoding.
const String TARGET_CLASS    =  "BleuTrayTarget";
// NSVariableStatusItemLength: the item sizes itself to its content (NSStatusBar.h).
const double VARIABLE_LENGTH = -1.0;
// How long the worker waits for a command before it checks for a stop request.
const Duration WAIT_INTERVAL =  (Duration)1_000_000;

struct AppKitBackend
{
	Allocator allocator;
	bool publish_own;
	tray::OwnItem own;
	TrayHub* hub;
	Mailbox{tray::Command}* mailbox; // the worker's mailbox while the service runs
	objc::Obj status_bar;
	objc::Obj status_item;
	objc::Obj menu;
	objc::Obj target;
}

const Driver DRIVER = {
	.info = { "appkit", "NSStatusItem in the menu bar", 10 },
	.id = APPKIT,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// The menu bar is always there on macOS.
fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(
		availability::no(
			availability::Reason.UNSUPPORTED_OS,
			"macOS has no public API to list other applications' menu-bar items (Accessibility, not used)"
		)
	);
	if (options.publish_own)
	{
		capabilities.set(tray::Cap.PUBLISH_OWN_ICON, availability::YES);
		capabilities.set(tray::Cap.OWN_MENU, availability::YES);
	}
	else
	{
		capabilities.set(
			tray::Cap.PUBLISH_OWN_ICON,
			availability::no(availability::Reason.DISABLED_BY_POLICY, "publish_own is false")
		);
		capabilities.set(
			tray::Cap.OWN_MENU,
			availability::no(availability::Reason.DISABLED_BY_POLICY, "publish_own is false")
		);
	}
	AppKitBackend* backend = alloc::new(
		allocator,
		AppKitBackend,
		{ .allocator = allocator, .publish_own = options.publish_own }
	);
	backend.own = convert::copy_own(options.own, allocator);
	if (options.publish_own)
	{
		if (catch err = build_status_item(backend))
		{
			close_status_item(backend);
			convert::free_own(backend.own, allocator);
			alloc::free(allocator, backend);
			return err~;
		}
	}
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	AppKitBackend* backend = (AppKitBackend*)state;
	close_status_item(backend);
	convert::free_own(backend.own, allocator);
	alloc::free(allocator, backend);
}

// Remove the status item from the bar and release what was built for it. Safe when partly built.
fn void close_status_item(AppKitBackend* backend)
{
	if (!backend.status_item.is_nil()) backend.status_bar.send_void("removeStatusItem:", backend.status_item.ptr);
	backend.menu.close();
	backend.target.close();
	backend.status_item.close();
	backend.status_bar.close();
}

// The status item with its icon (or title), its tooltip, and its menu.
fn void? build_status_item(AppKitBackend* backend)
{
	backend.status_bar = objc::borrow(objc::class_named("NSStatusBar").send(ObjId, "systemStatusBar"));
	backend.status_item = objc::borrow(backend.status_bar.send_id("statusItemWithLength:", VARIABLE_LENGTH));
	objc::Obj button = objc::borrow(backend.status_item.send_id("button"));
	defer button.close();
	objc::Obj tooltip = foundation::from_string(backend.own.title);
	defer tooltip.close();
	button.send_void("setToolTip:", tooltip.ptr);
	if (try image = load_image(backend.own.icon))
	{
		defer image.close();
		button.send_void("setImage:", image.ptr);
	}
	else
	{
		// No icon file: the title stands in for it.
		button.send_void("setTitle:", tooltip.ptr);
	}
	backend.target = build_target(backend);
	backend.menu = build_menu(backend);
	backend.status_item.send_void("setMenu:", backend.menu.ptr);
}

// The image in `path`, or UNAVAILABLE when there is none or it does not load.
fn objc::Obj? load_image(String path)
{
	if (path.len == 0) return error::UNAVAILABLE~;
	objc::Obj ns_path = foundation::from_string(path);
	defer ns_path.close();
	ObjId allocated   = objc::class_named("NSImage").send(ObjId, "alloc");
	ObjId initialised = objc::adopt(allocated).send_id("initWithContentsOfFile:", ns_path.ptr);
	objc::Obj loaded  = objc::adopt(initialised);
	if (loaded.is_nil()) return error::UNAVAILABLE~;
	return loaded;
}

// An instance of the target class, whose context is the backend. The class is defined once per process.
fn objc::Obj build_target(AppKitBackend* backend)
{
	ObjClass cls = objc::class_named(TARGET_CLASS);
	if (cls == (ObjClass)null)
	{
		// A failure here means the Objective-C runtime cannot define a class, which is not recoverable.
		objc::ClassBuilder builder = objc::begin_class(objc::class_named("NSObject"), TARGET_CLASS)!!;
		builder.add_context_ivar()!!;
		builder.method("menuItemClicked:", (void*)&on_menu_item, "v@:@")!!;
		cls = builder.finish();
	}
	objc::Obj target = objc::adopt(cls.send(ObjId, "new"));
	objc::set_context(target.ptr, backend);
	return target;
}

// The menu of our icon: one NSMenuItem per entry, tagged with the entry's id.
fn objc::Obj build_menu(AppKitBackend* backend)
{
	objc::Obj menu = objc::adopt(objc::class_named("NSMenu").send(ObjId, "new"));
	for (sz i = 0; i < backend.own.menu.len; i++)
	{
		add_menu_entry(menu, backend.target, backend.own.menu[i]);
	}
	return menu;
}

fn void add_menu_entry(objc::Obj menu, objc::Obj target, tray::OwnMenuEntry entry)
{
	if (entry.is_separator)
	{
		objc::Obj separator = objc::borrow(objc::class_named("NSMenuItem").send(ObjId, "separatorItem"));
		defer separator.close();
		menu.send_void("addItem:", separator.ptr);
		return;
	}
	@pool()
	{
		String label    = convert::mnemonic_free(entry.label, tmem);
		objc::Obj title = foundation::from_string(label);
		objc::Obj key   = foundation::from_string("");
		ObjId allocated = objc::class_named("NSMenuItem").send(ObjId, "alloc");
		objc::Obj item = objc::adopt(objc::adopt(allocated)
			.send_id("initWithTitle:action:keyEquivalent:", title.ptr, objc::selector("menuItemClicked:"), key.ptr));
		item.send_void("setTag:", (long)entry.id);
		item.send_void("setTarget:", target.ptr);
		item.send_void("setEnabled:", entry.enabled);
		menu.send_void("addItem:", item.ptr);
		item.close();
		key.close();
		title.close();
	};
}

<*
 The menu's action. AppKit calls it on the main thread: it reads the entry's tag and posts a
 command. Nothing else here touches the worker.
*>
fn void on_menu_item(ObjId self, ObjSel selector, ObjId sender)
{
	AppKitBackend* backend = (AppKitBackend*)objc::context_of(self);
	if (backend == null || backend.mailbox == null) return;
	objc::Obj item = { .ptr = sender };
	long tag       = item.send_long("tag");
	// A post after the service closed is refused: the click is dropped, as it should be.
	if (catch backend.mailbox.post({ .kind = OWN_MENU_CLICK, .menu_id = (int)tag }))
	{
	}
}

// The worker: publishes once, then delivers the menu clicks the callback posts until stopped.
fn void run(void* state, TrayHub* hub, Host{tray::Command}* host)
{
	AppKitBackend* backend = (AppKitBackend*)state;
	backend.hub = hub;
	backend.mailbox = host.mailbox();
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	Snapshot{tray::State}* snapshot = hub.begin();
	snapshot.value = { .own_published = backend.publish_own };
	hub.publish_if_changed(snapshot);
	tray::Command[8] commands;
	while (!host.stopping())
	{
		if (catch poller.wait(WAIT_INTERVAL))
		{
			// TIMEOUT is the normal tick.
		}
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++)
		{
			if (commands[i].kind == OWN_MENU_CLICK) emit_menu_click(backend, commands[i].menu_id);
		}
	}
}

// Deliver a click on entry `id` of our menu.
fn void emit_menu_click(AppKitBackend* backend, int id)
{
	Snapshot{tray::Event}* packet = backend.hub.emit_begin();
	packet.value = { .kind = tray::EventKind.OWN_MENU_CLICKED, .item_id = "", .menu_id = id };
	backend.hub.emit(packet);
}