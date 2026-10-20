<*
 Ownership of the StatusNotifierWatcher name, the registrations, and our own registrations.

 When no other process owns the watcher name, this process takes it and serves the registry
 itself (`watcher_served`). Otherwise it reads the other watcher's registry and follows its
 signals. Either way it registers as a host, and registers our own icon when published.
 Owner changes and lost names only queue work: `attach_watcher` runs from the worker.
*>
module bleu::tray::sni @feat(LINUX);
import std::collections::list, bleu::dbus::bus, bleu::dbus::connection, bleu::dbus::match, bleu::dbus::message, bleu::dbus::ownership, bleu::dbus::server, bleu::dbus::value, bleu::dbus::marshal, bleu::error, bleu::tray, bleu::tray::convert;

// Asks for the watcher name, without queueing: it is ours only if nobody else holds it.
fn void? subscribe_watcher_owner(SniBackend* b)
{
	if (b.watcher_watch_set) return;
	b.watcher_owner_sub = b.connection.watch_name(WATCHER_NAME, &on_watcher_owner, b)!;
	b.watcher_watch_set = true;
}

// The watcher name changed owner. Its new owner is the text of the work item.
fn void on_watcher_owner(void* context, Message* signal)
{
	SniBackend* b = (SniBackend*)context;
	String name;
	String old_owner;
	String new_owner;
	if (catch bus::name_owner_change(signal, &name, &old_owner, &new_owner)) return;
	push_pending(b, WATCHER_CHANGED, 0, ID, new_owner);
}

// We held the watcher name and lost it, for example to a replacement: serve nothing and attach again.
fn void on_watcher_lost(void* context, String name)
{
	SniBackend* b = (SniBackend*)context;
	push_pending(b, WATCHER_LOST, 0, ID, "");
}

<*
 Work out who serves the watcher now, and register this process with it. Called after a
 (re)connect, when the watcher changed owner, and when the watcher name was lost. A process
 that serves the watcher does nothing here, because its owner-change is its own acquisition.
*>
fn void attach_watcher(SniBackend* b)
{
	if (b.watcher_served) return;
	forget_records(b);
	drop_registry(b);
	b.host_known = false;
	b.own_published = false;
	b.watcher_present = false;
	if (!try_serve(b))
	{
		remote_attach(b);
	}
	register_host(b);
	if (b.publish_own && b.own_item_name != null) register_own(b);
	b.dirty = true;
}

// Forget the registry and the signals that kept it up to date.
fn void drop_registry(SniBackend* b)
{
	if (b.registry_subs_set)
	{
		for (usz i = 0; i < 2; i++)
		{
			if (catch b.connection.unsubscribe(b.registry_subs[i]))
			{
			}
		}
		b.registry_subs_set = false;
	}
	clear_registry(b);
	if (b.watcher_name)
	{
		if (catch b.watcher_name.release())
		{
		}
		b.watcher_name = null;
	}
}

// Forget every registration we serve, freeing the copies the registry held.
fn void clear_registry(SniBackend* b)
{
	for (sz i = 0; i < b.registry.len(); i++)
	{
		alloc::free(b.allocator, b.registry[i].ptr);
	}
	b.registry.clear();
}

// Take the watcher name without queueing. True when we serve the watcher from now on.
fn bool try_serve(SniBackend* b)
{
	if (try owned = b.connection.own_name(WATCHER_NAME, bus::NAME_DO_NOT_QUEUE, &on_name_acquired, &on_watcher_lost, b))
	{
		b.watcher_name = owned;
		b.watcher_served = true;
		b.watcher_present = true;
		return true;
	}
	return false;
}

// Follow a watcher that another process serves: its registry now, and its signals from now on.
fn void remote_attach(SniBackend* b)
{
	if (!(b.connection.name_has_owner(WATCHER_NAME) ?? false)) return;
	b.watcher_present = true;
	if (catch subscribe_registry(b)) return;
	if (catch read_registered(b))
	{
	}
}

// Subscribe to the watcher's registration signals. Both are routed through the work queue.
fn void? subscribe_registry(SniBackend* b)
{
	String[2] members = { REGISTERED_SIGNAL, UNREGISTERED_SIGNAL };
	for (usz i = 0; i < 2; i++)
	{
		match::Match rule;
		rule.init(b.allocator);
		rule.with_type(message::MessageType.SIGNAL)!;
		rule.with_sender(WATCHER_NAME)!;
		rule.with_path(WATCHER_PATH)!;
		rule.with_interface(WATCHER_INTERFACE)!;
		rule.with_member(members[i])!;
		b.registry_subs[i] = b.connection.subscribe(rule, &on_registration, b)!;
	}
	b.registry_subs_set = true;
}

// A registration or an unregistration of an item, as the other watcher announces it.
fn void on_registration(void* context, Message* signal)
{
	SniBackend* b = (SniBackend*)context;
	if (try rd = signal.reader())
	{
		String text      = rd.read_string() ?? "";
		PendingKind kind = signal.member == REGISTERED_SIGNAL ? ADD_ITEM : REMOVE_ITEM;
		push_pending(b, kind, 0, ID, text);
	}
}

// Queue an ADD for every item the other watcher has registered.
fn void? read_registered(SniBackend* b)
{
	Message* reply = get_property(b, WATCHER_NAME, WATCHER_PATH, WATCHER_INTERFACE, "RegisteredStatusNotifierItems")!;
	defer reply.release();
	Reader rd = reply.reader()!;
	if (rd.begin_variant()! != "as") return error::PROTOCOL~;
	rd.begin_array()!;
	while (rd.has_more())
	{
		push_pending(b, ADD_ITEM, 0, ID, rd.read_string()!);
	}
	rd.end_array()!;
	rd.end_variant()!;
}

// Register this process as a host, with the watcher we serve or the one we follow.
fn void register_host(SniBackend* b)
{
	if (b.watcher_served)
	{
		b.host_known = true;
		return;
	}
	if (!b.watcher_present) return;
	if (catch call_register_host(b, b.host_bus)) return;
	b.host_known = true;
}

// Register our own icon: directly when we serve the watcher, otherwise with the other watcher.
fn void register_own(SniBackend* b)
{
	if (b.watcher_served)
	{
		add_registration(b, b.own_item_id);
		b.own_published = true;
		return;
	}
	if (!b.watcher_present) return;
	if (catch call_register_item(b, b.own_bus)) return;
	b.own_published = true;
}

<*
 Add `item` (its canonical id) to the registry we serve, and announce it. Returns false when it
 was already there.
*>
fn bool add_registration(SniBackend* b, String item)
{
	if (contains(&b.registry, item)) return false;
	b.registry.push(convert::copy_text(item, b.allocator));
	emit_watcher_signal(b, REGISTERED_SIGNAL, item);
	return true;
}

// Remove `item` from the registry we serve and announce it. Returns false when it was not there.
fn bool remove_registration(SniBackend* b, String item)
{
	for (sz i = 0; i < b.registry.len(); i++)
	{
		if (b.registry[i] != item) continue;
		alloc::free(b.allocator, b.registry[i].ptr);
		b.registry.remove_at(i);
		emit_watcher_signal(b, UNREGISTERED_SIGNAL, item);
		return true;
	}
	return false;
}

fn bool contains(List{String}* list, String item)
{
	for (sz i = 0; i < list.len(); i++)
	{
		if (list.get(i) == item) return true;
	}
	return false;
}

// One of the watcher's item signals, sent to the bus. A signal that cannot be sent is not retried:
// the registry is authoritative, and a host that missed it reads the registry again.
fn void emit_watcher_signal(SniBackend* b, String member, String item)
{
	@pool()
	{
		if (try text = value::str(tmem, item))
		{
			if (catch b.server.emit_signal(WATCHER_PATH, WATCHER_INTERFACE, member, { text }))
			{
			}
		}
	};
}