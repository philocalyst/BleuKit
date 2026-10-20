<*
 Publishing: build the complete state from the records, publish it when something changed, and
 deliver the events queued since the last publish, after the state they describe.
*>
module bleu::tray::sni @feat(LINUX);
import bleu::observe, bleu::service, bleu::tray;

<* Publish the state if a change is pending, then deliver the queued events. *>
fn void publish(SniBackend* b, TrayHub* hub)
{
	if (b.dirty)
	{
		b.dirty = false;
		Snapshot{State}* snapshot = hub.begin();
		snapshot.value = build_state(b, snapshot.allocator());
		hub.publish_if_changed(snapshot);
	}
	flush_events(b, hub);
}

// The whole state, with every string and pixmap owned by `a`.
fn tray::State build_state(SniBackend* b, Allocator a)
{
	tray::State state = {
		.watcher_present = b.watcher_present,
		.watcher_served = b.watcher_served,
		.host_registered = b.host_known,
		.own_published = b.own_published,
		.items = copy_items(b, a),
	};
	return state;
}

fn tray::Item[] copy_items(SniBackend* b, Allocator a)
{
	if (b.items.len() == 0) return {};
	tray::Item[] items = alloc::new_array(a, tray::Item, b.items.len());
	for (sz i = 0; i < b.items.len(); i++)
	{
		items[i] = copy_item(b.items[i], a);
	}
	return items;
}

// One record as the snapshot's item: its properties copied, and its menu flattened.
fn tray::Item copy_item(ItemRecord* r, Allocator a)
{
	tray::Item item = r.item;
	item.id = copy_text(r.item.id, a);
	item.bus_name = copy_text(r.item.bus_name, a);
	item.object_path = copy_text(r.item.object_path, a);
	item.item_id = copy_text(r.item.item_id, a);
	item.title = copy_text(r.item.title, a);
	item.icon_name = copy_text(r.item.icon_name, a);
	item.icon_theme_path = copy_text(r.item.icon_theme_path, a);
	item.icon_pixmaps = copy_pixmaps(r.item.icon_pixmaps, a);
	item.attention_icon_name = copy_text(r.item.attention_icon_name, a);
	item.attention_icon_pixmaps = copy_pixmaps(r.item.attention_icon_pixmaps, a);
	item.overlay_icon_name = copy_text(r.item.overlay_icon_name, a);
	item.overlay_icon_pixmaps = copy_pixmaps(r.item.overlay_icon_pixmaps, a);
	item.tooltip = {
		.icon_name = copy_text(r.item.tooltip.icon_name, a),
		.icon_pixmaps = copy_pixmaps(r.item.tooltip.icon_pixmaps, a),
		.title = copy_text(r.item.tooltip.title, a),
		.description = copy_text(r.item.tooltip.description, a),
	};
	item.menu_path = copy_text(r.item.menu_path, a);
	item.menu = r.item.menu_path.len > 0 ? copy_menu(&r.menu, a) : {};
	return item;
}

fn tray::Pixmap[] copy_pixmaps(tray::Pixmap[] source, Allocator a)
{
	if (source.len == 0) return {};
	tray::Pixmap[] pixmaps = alloc::new_array(a, tray::Pixmap, source.len);
	for (sz i = 0; i < source.len; i++)
	{
		pixmaps[i] = { .width = source[i].width, .height = source[i].height, .pixels = copy_text(source[i].pixels, a) };
	}
	return pixmaps;
}

// Deliver the queued events, each with its own copy of the item identifier.
fn void flush_events(SniBackend* b, TrayHub* hub)
{
	while (try event = b.events.pop_first())
	{
		Snapshot{Event}* packet = hub.emit_begin();
		packet.value = {
			.kind = event.kind,
			.item_id = copy_text(event.item_id, packet.allocator()),
			.menu_id = event.menu_id,
			.x = event.x,
			.y = event.y,
		};
		hub.emit(packet);
		if (event.item_id.len > 0) alloc::free(b.allocator, event.item_id.ptr);
	}
}
