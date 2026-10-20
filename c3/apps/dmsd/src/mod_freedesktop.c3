<*
 The `freedesktop` module: the desktop's colour scheme on `bleu::appearance`, and the
 screensaver state that DMS streams beside it.

 Methods: `freedesktop.getState`, `freedesktop.settings.getColorScheme`. Refused: the
 `freedesktop.accounts.*` methods (AccountsService is not used by Bleu) and
 `freedesktop.settings.setIconTheme` (bleu_appearance writes the colour scheme and the wallpaper
 only). Topics: `freedesktop` (DMS's `FreedeskState`) and `freedesktop.screensaver`
 (`ScreensaverState`), which DMS streams from the same manager (router.go:117, server.go:606-622).

 Source of every shape and rule: `core/internal/server/freedesktop/` (types.go, handlers.go) at DMS
 master 8be08999. The colour scheme values are the freedesktop settings portal's
 `org.freedesktop.appearance color-scheme`: 0 no preference, 1 prefer dark, 2 prefer light
 (bleu_appearance's `ColorScheme` names them the same way). Deviations are listed in docs/DMSD.md.
*>
module dmsd::freedesktop_mod;
import bleu::appearance, bleu::error, bleu::ipc, bleu::observe, dmsd::contract, dmsd::wire, dmsd::replies;

const String[2] TOPICS       = { "freedesktop", "freedesktop.screensaver" };
const String[1] CAPABILITIES = { "freedesktop" };

// The colour scheme values of the settings portal (see the header).
const uint SCHEME_NO_PREFERENCE = 0;
const uint SCHEME_PREFER_DARK   = 1;
const uint SCHEME_PREFER_LIGHT  = 2;

// The reply texts of the refused methods (replies.c3).
const String NOT_SUPPORTED_ACCOUNTS = "not supported: user accounts are managed by AccountsService, which Bleu does not use";
const String NOT_SUPPORTED_ICON     = "not supported: bleu_appearance has no icon theme setter (it writes the colour scheme and the wallpaper)";

// The refused methods of this module: each answers `not supported: <why>`.
const replies::Refusal[7] REFUSED = {
	{ .method = "freedesktop.accounts.setIconFile", .text = NOT_SUPPORTED_ACCOUNTS },
	{ .method = "freedesktop.accounts.setRealName", .text = NOT_SUPPORTED_ACCOUNTS },
	{ .method = "freedesktop.accounts.setEmail", .text = NOT_SUPPORTED_ACCOUNTS },
	{ .method = "freedesktop.accounts.setLanguage", .text = NOT_SUPPORTED_ACCOUNTS },
	{ .method = "freedesktop.accounts.setLocation", .text = NOT_SUPPORTED_ACCOUNTS },
	{ .method = "freedesktop.accounts.getUserIconFile", .text = NOT_SUPPORTED_ACCOUNTS },
	{ .method = "freedesktop.settings.setIconTheme", .text = NOT_SUPPORTED_ICON },
};

// The screensaver state, as DMS's `ScreensaverState` (types.go:46-51), which dmsd cannot read (see the header of `render_screensaver`).
const String SCREENSAVER_STATE = "{\"available\":false,\"active\":false,\"inhibited\":false,\"inhibitors\":[]}";

<* The module's runtime state. Allocated in `start`, freed in `stop`. *>
struct FreedesktopModule
{
	appearance::Appearance* service;
	contract::StatePump state_pump;
	observe::WatchId{appearance::State} watch_id;
}

// The colour scheme of the newest reading as the portal number, and whether it is available.
fn uint scheme_value(appearance::ColorScheme scheme) @inline
{
	switch (scheme)
	{
		case appearance::ColorScheme.NO_PREFERENCE: return SCHEME_NO_PREFERENCE;
		case appearance::ColorScheme.DARK: return SCHEME_PREFER_DARK;
		case appearance::ColorScheme.LIGHT: return SCHEME_PREFER_LIGHT;
	}
}

// The `settings` object: `available`, and the colour scheme of the newest reading (0 before the first one).
fn void? write_settings(wire::Line* line, appearance::Appearance* service, observe::Snapshot{appearance::State}* snapshot) @private
{
	bool available = service.capability(appearance::Cap.COLOR_SCHEME).ok() && snapshot != null;
	uint scheme    = snapshot != null ? scheme_value(snapshot.value.color_scheme) : SCHEME_NO_PREFERENCE;
	line.writer.begin_object()!;
	wire::key_bool(&line.writer, "available", available)!;
	wire::key_uint(&line.writer, "colorScheme", scheme)!;
	line.writer.end_object()!;
}

// `accounts` with `available` false: AccountsService is not read, so every field is Go's zero value.
fn void? write_accounts(wire::Line* line) @private
{
	line.writer.begin_object()!;
	wire::key_bool(&line.writer, "available", false)!;
	wire::key_string(&line.writer, "userPath", "")!;
	wire::key_string(&line.writer, "iconFile", "")!;
	wire::key_string(&line.writer, "realName", "")!;
	wire::key_string(&line.writer, "userName", "")!;
	wire::key_int(&line.writer, "accountType", 0)!;
	wire::key_string(&line.writer, "homeDirectory", "")!;
	wire::key_string(&line.writer, "shell", "")!;
	wire::key_string(&line.writer, "email", "")!;
	wire::key_string(&line.writer, "language", "")!;
	wire::key_string(&line.writer, "location", "")!;
	wire::key_bool(&line.writer, "locked", false)!;
	wire::key_int(&line.writer, "passwordMode", 0)!;
	wire::key_uint(&line.writer, "uid", 0)!;
	line.writer.end_object()!;
}

// `freedesktop.getState` (types.go:53-57): accounts, settings and screensaver.
fn String? render_state(Allocator allocator, appearance::Appearance* service, observe::Snapshot{appearance::State}* snapshot)
{
	wire::Line line;
	line.begin(allocator);
	line.writer.begin_object()!;
	line.writer.key("accounts")!;
	write_accounts(&line)!;
	line.writer.key("settings")!;
	write_settings(&line, service, snapshot)!;
	line.writer.key("screensaver")!;
	line.writer.put_token(SCREENSAVER_STATE)!;
	line.writer.end_object()!;
	return line.finish();
}

// The newest reading of the appearance service, or null before the first one (the caller releases a non-null snapshot).
fn observe::Snapshot{appearance::State}*? FreedesktopModule.reading(&self) => self.service.latest();

// The pump's encoder: the whole state, in temporary memory.
fn String? encode_state(void* context, Allocator allocator)
{
	FreedesktopModule* m = (FreedesktopModule*)context;
	if (try snapshot = m.reading())
	{
		defer snapshot.release();
		return render_state(allocator, m.service, snapshot);
	}
	return render_state(allocator, m.service, null);
}

// Listener: runs on the appearance worker's thread. It only marks the pump dirty.
fn void on_state(void* context, observe::Snapshot{appearance::State}* snapshot)
{
	contract::StatePump* pump = (contract::StatePump*)context;
	pump.notify();
}

fn void handle_get_state(void* context, ipc::Call* call)
{
	FreedesktopModule* m = (FreedesktopModule*)context;
	@pool()
	{
		if (try snapshot = m.reading())
		{
			defer snapshot.release();
			if (try line = render_state(tmem, m.service, snapshot))
			{
				call.respond_raw(line);
			}
			else
			{
				call.respond_error(contract::failure_text("failed to read the desktop state"));
			}
		}
		else if (try line = render_state(tmem, m.service, null))
		{
			call.respond_raw(line);
		}
		else
		{
			call.respond_error(contract::failure_text("failed to read the desktop state"));
		}
	};
}

// `freedesktop.settings.getColorScheme`: asks the desktop for a fresh reading, then answers `{"colorScheme":N}`
// with the newest one (handlers.go:131-139; the refresh is asynchronous, so the reading may still be the older one).
fn void handle_get_color_scheme(void* context, ipc::Call* call)
{
	FreedesktopModule* m = (FreedesktopModule*)context;
	@pool()
	{
		if (catch m.service.refresh())
		{
			call.respond_error(contract::failure_text("failed to read the colour scheme"));
			return;
		}
		if (try snapshot = m.reading())
		{
			defer snapshot.release();
			call.respond_raw(string::tformat("{\"colorScheme\":%d}", scheme_value(snapshot.value.color_scheme)));
		}
		else
		{
			call.respond_error("colour scheme not read yet");
		}
	};
}

// Answers the refused methods (replies.c3).
fn void handle_refused(void* context, ipc::Call* call)
{
	replies::answer(REFUSED[..], call);
}

<* Start the module, or report why not and return false: no desktop settings service. *>
fn bool start(contract::Context* context, contract::Module* self)
{
	appearance::Options options = { .backend = appearance::Backend.AUTO };
	appearance::Appearance* service;
	if (try opened = appearance::open(context.allocator, options))
	{
		service = opened;
	}
	else
	{
		contract::warn("freedesktop: not started: %s", contract::failure_text("no backend"));
		return false;
	}
	FreedesktopModule* m = alloc::new(context.allocator, FreedesktopModule);
	m.service = service;
	ipc::Topic* state_topic = context.server.register_topic("freedesktop")!!;
	ipc::Topic* screensaver_topic = context.server.register_topic("freedesktop.screensaver")!!;
	context.server.register_method("freedesktop.getState", &handle_get_state, m)!!;
	context.server.register_method("freedesktop.settings.getColorScheme", &handle_get_color_scheme, m)!!;
	replies::register_all(context.server, REFUSED[..], &handle_refused)!!;
	m.state_pump.start("freedesktop", state_topic, &encode_state, m)!!;
	// The screensaver state never changes here (see render_state), so it is published once, before the server starts.
	screensaver_topic.publish(SCREENSAVER_STATE)!!;
	m.watch_id = service.watch(&on_state, &m.state_pump);
	m.state_pump.notify();
	self.state = m;
	return true;
}

<* Stop the module: no more publications, then the service is closed. The server has stopped already. *>
fn void stop(contract::Context* context, contract::Module* self)
{
	FreedesktopModule* m = (FreedesktopModule*)self.state;
	m.service.unwatch(m.watch_id)!!;
	m.state_pump.stop();
	m.state_pump.free();
	m.service.close();
	alloc::free(context.allocator, m);
}

<* The module's descriptor for `main`. A global constant, so its slices point at static data. *>
const contract::Module DESCRIPTOR = {
	.name = "freedesktop",
	.start = &start,
	.stop = &stop,
	.topics = TOPICS[..],
	.capabilities = CAPABILITIES[..],
};

fn contract::Module descriptor() => DESCRIPTOR;
