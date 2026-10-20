// Live probe of the tray host against a private session bus. tests/run.sh starts the bus, the
// Python fake items and the Python host client, then runs this program with compile-run. Each
// observation is printed on one line with a fixed prefix, so run.sh can check them with grep.
module bleu::tray::probe @feat(LINUX);
import std::io, std::time, bleu::error, bleu::observe, bleu::stream, bleu::tray, bleu::operation;

// How long one wait for a state change lasts, and how many waits a phase gets.
const Duration STEP    = (Duration)500_000;
const int ROUNDS       = 40;
const String FAKE_ITEM = "org.test.FakeItem/StatusNotifierItem";

alias Check = fn bool(tray::State* state);

fn String kind_name(tray::EventKind kind)
{
	switch (kind)
	{
		case ITEM_ADDED: return "ITEM_ADDED";
		case ITEM_REMOVED: return "ITEM_REMOVED";
		case ITEM_CHANGED: return "ITEM_CHANGED";
		case MENU_CHANGED: return "MENU_CHANGED";
		case OWN_ACTIVATED: return "OWN_ACTIVATED";
		case OWN_SECONDARY_ACTIVATED: return "OWN_SECONDARY_ACTIVATED";
		case OWN_MENU_CLICKED: return "OWN_MENU_CLICKED";
	}
}

fn void print_item(tray::Item* item)
{
	io::printfn(
		"ITEM id=%s title=%s status=%d category=%d menu=%s menu_entries=%d",
		item.id,
		item.title,
		(int)item.status,
		(int)item.category,
		item.menu_path,
		item.menu.len
	);
	io::printfn(
		"ICON name=%s pixmaps=%d attention=%s overlay=%s tooltip=%s",
		item.icon_name,
		item.icon_pixmaps.len,
		item.attention_icon_name,
		item.overlay_icon_name,
		item.tooltip.title
	);
	for (usz p = 0; p < item.icon_pixmaps.len; p++)
	{
		tray::Pixmap* pm = &item.icon_pixmaps[p];
		io::printfn(
			"PIXMAP %dx%d bytes=%d first=%d,%d,%d,%d",
			pm.width,
			pm.height,
			pm.pixels.len,
			(int)pm.pixels[0],
			(int)pm.pixels[1],
			(int)pm.pixels[2],
			(int)pm.pixels[3]
		);
	}
	for (usz m = 0; m < item.menu.len; m++)
	{
		tray::MenuItem* entry = &item.menu[m];
		io::printfn(
			"MENU index=%d id=%d label=%s separator=%d enabled=%d submenu=%d loaded=%d first=%d count=%d toggle=%d state=%d shortcut=%s",
			m,
			entry.id,
			entry.label,
			entry.is_separator ? 1 : 0,
			entry.enabled ? 1 : 0,
			entry.has_submenu ? 1 : 0,
			entry.submenu_loaded ? 1 : 0,
			entry.first_child,
			entry.child_count,
			(int)entry.toggle,
			(int)entry.toggle_state,
			entry.shortcut
		);
	}
}

fn void print_state(tray::State* state, ulong generation)
{
	io::printfn(
		"STATE gen=%d items=%d watcher=%d served=%d host=%d own=%d",
		generation,
		state.items.len,
		state.watcher_present ? 1 : 0,
		state.watcher_served ? 1 : 0,
		state.host_registered ? 1 : 0,
		state.own_published ? 1 : 0
	);
}

// Wait for a state that satisfies `check`: the current one first, then each new state, printed.
// The caller releases the result.
fn Snapshot{tray::State}*? until(tray::Tray* host, ulong* seen, Check check, String what)
{
	if (try current = host.latest())
	{
		*seen = current.generation;
		if (check(&current.value)) return current;
		current.release();
	}
	for (int i = 0; i < ROUNDS; i++)
	{
		if (try snap = host.wait_after(*seen, STEP))
		{
			*seen = snap.generation;
			print_state(&snap.value, snap.generation);
			for (usz k = 0; k < snap.value.items.len; k++) print_item(&snap.value.items[k]);
			if (check(&snap.value)) return snap;
			snap.release();
		}
	}
	io::printfn("TIMEOUT waiting for %s", what);
	return TIMEOUT~;
}

fn bool own_published(tray::State* state) => state.own_published;
fn bool has_item(tray::State* state) => state.items.len > 0;
fn bool no_items(tray::State* state) => state.items.len == 0;
fn bool renamed(tray::State* state) => state.items.len > 0 && state.items[0].title == "Renamed Item";
fn bool icon_changed(tray::State* state) => state.items.len > 0 && state.items[0].icon_name == "face-wink";
fn bool status_changed(
	tray::State* state
) => state.items.len > 0 && state.items[0].status == NEEDS_ATTENTION
	&& state.items[0].overlay_icon_name == "emblem-new";
fn bool menu_renamed(
	tray::State* state
) => state.items.len > 0 && state.items[0].menu.len > 2 && state.items[0].menu[2].label == "Recents";

fn void report(String what, bool ok)
{
	io::printfn("%s %s", what, ok ? "ok" : "failed");
}

// Wait for an operation, print its outcome, and release it.
fn void finish(String what, CommandOp* op)
{
	defer op.release();
	if (catch err = op.wait(time::ms(3000)))
	{
		io::printfn("%s failed %s", what, err);
		return;
	}
	io::printfn("%s ok", what);
}

fn void drain_events(stream::Reader{tray::Event}* events)
{
	for (int i = 0; i < 60; i++)
	{
		if (try packet = events.next(time::ms(100)))
		{
			io::printfn(
				"EVENT %s item=%s menu=%d x=%d y=%d",
				kind_name(packet.value.kind),
				packet.value.item_id,
				packet.value.menu_id,
				packet.value.x,
				packet.value.y
			);
			packet.release();
		}
	}
}

fn int main()
{
	tray::OwnMenuEntry[] menu = {
		{ .id = 1, .label = "_Open", .enabled = true },
		{ .id = 2, .is_separator = true },
		{ .id = 3, .label = "Quit", .enabled = true },
	};
	tray::Options options = {
		.publish_own = true,
		.own = { .title = "Bleu Probe", .icon = "applications-internet", .menu = menu }
	};
	tray::Tray* host = tray::open(mem, options)!!;
	defer host.close();
	io::printfn("BACKEND %s", host.backend_name());
	stream::Reader{tray::Event}* events = host.subscribe()!!;
	defer events.release();
	ulong seen = 0;

	if (try snap = until(host, &seen, &own_published, "own icon"))
	{
		snap.release();
		report("OWN_PUBLISHED", true);
	}
	else
	{
		return 1;
	}
	if (try snap = until(host, &seen, &has_item, "a tray item"))
	{
		tray::Item* item = &snap.value.items[0];
		String id        = item.id;
		// Submenu 2 has children only once it is opened: AboutToShow reads them.
		finish("OPEN_SUBMENU", host.open_submenu(id, 2)!!);
		finish("CLICK_MENU", host.click_menu(id, 6)!!);
		finish("ACTIVATE", host.activate(id, 10, 20)!!);
		finish("SCROLL", host.scroll(id, 1, false)!!);
		finish("SECONDARY_ACTIVATE", host.secondary_activate(id, 1, 2)!!);
		finish("CONTEXT_MENU", host.context_menu(id, 3, 4)!!);
		snap.release();
	}
	else
	{
		return 1;
	}
	if (try snap = until(host, &seen, &icon_changed, "icon change"))
	{
		snap.release();
		report("ICON_CHANGED", true);
	}
	if (try snap = until(host, &seen, &renamed, "title change"))
	{
		snap.release();
		report("TITLE_CHANGED", true);
	}
	if (try snap = until(host, &seen, &status_changed, "status, attention and overlay"))
	{
		snap.release();
		report("STATUS_CHANGED", true);
	}
	if (try snap = until(host, &seen, &menu_renamed, "menu layout update"))
	{
		snap.release();
		report("MENU_RENAMED", true);
	}
	drain_events(events);
	if (try snap = until(host, &seen, &no_items, "the item to vanish"))
	{
		snap.release();
		report("ITEM_VANISHED", true);
	}
	io::printfn("DONE");
	return 0;
}