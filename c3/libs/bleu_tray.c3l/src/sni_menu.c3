<*
 The DBusMenu menu of an item (com.canonical.dbusmenu, libdbusmenu's protocol).

 The tree is read lazily: the root's children arrive with it, a submenu's children arrive when
 it is opened (AboutToShow, then GetLayout). The tree lives in the item's menu arena, and every
 reload rebuilds it there, keeping the submenus that were loaded. `copy_menu` flattens the
 tree into the snapshot, breadth first, so each entry's children are contiguous.

 Sources: libdbusmenu com.canonical.dbusmenu.xml (GetLayout, AboutToShow, Event); the property
 names and defaults are the dox table of the same file.
*>
module bleu::tray::sni @feat(LINUX);
import std::collections::list, bleu::dbus::marshal, bleu::dbus::message, bleu::error, bleu::tray, bleu::tray::convert, bleu::operation;

// Separator between the keys of a shortcut chord when it is shown as text.
const String SHORTCUT_SEPARATOR  = "+";
// The variant contents of a menu node: (id, properties, children).
const String MENU_NODE_SIGNATURE = "(ia{sv}av)";

// One menu entry as read from the application. Its children are arena-allocated too.
struct MenuNode
{
	int id;
	bool is_separator;
	String label;
	bool enabled;
	bool visible;
	String icon_name;
	String shortcut;
	Toggle toggle;
	ToggleState toggle_state;
	bool has_submenu;
	Disposition disposition;
	MenuNode[] children;
}

// A GetLayout reply: the revision and the node it was asked for, with its children read.
struct Layout
{
	uint revision;
	MenuNode root;
}

// Read the whole menu from the root, then the submenus that were open, so the user sees what they had.
fn void? reload_menu(SniBackend* b, ItemRecord* r, int extra)
{
	if (r.item.menu_path.len == 0 || r.item.menu_path == NO_MENU_PATH)
	{
		r.menu_arena.reset();
		r.menu = { };
		r.item.menu_revision = 0;
		return;
	}
	List{int} wanted;
	wanted.init(b.allocator, 8);
	defer wanted.free();
	if (extra >= 0) wanted.push(extra);
	collect_loaded(&r.menu, &wanted);
	r.menu_arena.reset();
	Layout layout = fetch_layout(b, r, 0, 1)!;
	r.menu = layout.root;
	r.item.menu_revision = layout.revision;
	for (sz i = 0; i < wanted.len(); i++)
	{
		MenuNode* node = find_node(&r.menu, wanted[i]);
		if (node == null || !node.has_submenu || node.children.len > 0) continue;
		if (try sub = fetch_layout(b, r, wanted[i], 1))
		{
			node.children = sub.root.children;
		}
	}
}

// Append the ids of the submenus with loaded children, parents before their children.
fn void collect_loaded(MenuNode* node, List{int}* ids)
{
	if (node.has_submenu && node.children.len > 0) ids.push(node.id);
	for (sz i = 0; i < node.children.len; i++)
	{
		collect_loaded(&node.children[i], ids);
	}
}

// The node with this id, or null when the tree has none.
fn MenuNode* find_node(MenuNode* node, int id)
{
	if (node.id == id) return node;
	for (sz i = 0; i < node.children.len; i++)
	{
		MenuNode* found = find_node(&node.children[i], id);
		if (found != null) return found;
	}
	return null;
}

// GetLayout(parent, depth), parsed into the record's menu arena.
fn Layout? fetch_layout(SniBackend* b, ItemRecord* r, int parent, int depth)
{
	Message* reply = call_layout(b, r, parent, depth)!;
	defer reply.release();
	Reader rd     = reply.reader()!;
	uint revision = rd.read_u32()!;
	Allocator a   = &r.menu_arena;
	MenuNode root = parse_node(&rd, a, 0)!;
	return { .revision = revision, .root = root };
}

<* One `(ia{sv}av)` node: its id, its properties, and its children, each a variant of the same type. *>
fn MenuNode? parse_node(Reader* rd, Allocator a, usz depth)
{
	if (depth > MAX_MENU_DEPTH) return error::PROTOCOL~;
	rd.begin_struct()!;
	int id        = rd.read_i32()!;
	MenuNode node = { .id = id, .enabled = true, .visible = true };
	rd.begin_array()!;
	while (rd.has_more())
	{
		rd.begin_dict_entry()!;
		String key      = rd.read_string()!;
		String contents = rd.begin_variant()!;
		apply_menu_property(&node, key, contents, rd, a)!;
		rd.end_variant()!;
		rd.end_dict_entry()!;
	}
	rd.end_array()!;
	rd.begin_array()!;
	List{MenuNode} children;
	children.init(a, 4);
	while (rd.has_more())
	{
		String contents = rd.begin_variant()!;
		if (contents != MENU_NODE_SIGNATURE) return error::PROTOCOL~;
		children.push(parse_node(rd, a, depth + 1)!);
		rd.end_variant()!;
	}
	rd.end_array()!;
	node.children = children.array_view();
	rd.end_struct()!;
	return node;
}

<*
 Set one property of a node. Known keys with the expected type are read; everything else is
 skipped, so an unknown key from a newer application costs nothing.
*>
fn void? apply_menu_property(MenuNode* node, String key, String contents, Reader* rd, Allocator a)
{
	if (contents == "s")
	{
		if (key == "label")
		{
			node.label = convert::mnemonic_free(rd.read_string()!, a);
			return;
		}
		if (key == "icon-name")
		{
			node.icon_name = convert::copy_text(rd.read_string()!, a);
			return;
		}
		if (key == "type")
		{
			node.is_separator = rd.read_string()! == "separator";
			return;
		}
		if (key == "toggle-type")
		{
			node.toggle = convert::toggle_from(rd.read_string()!);
			return;
		}
		if (key == "children-display")
		{
			node.has_submenu = rd.read_string()! == "submenu";
			return;
		}
		if (key == "disposition")
		{
			node.disposition = convert::disposition_from(rd.read_string()!);
			return;
		}
	}
	if (contents == "b")
	{
		if (key == "enabled")
		{
			node.enabled = rd.read_bool()!;
			return;
		}
		if (key == "visible")
		{
			node.visible = rd.read_bool()!;
			return;
		}
	}
	if (contents == "i" && key == "toggle-state")
	{
		node.toggle_state = convert::toggle_state_from(rd.read_i32()!);
		return;
	}
	if (contents == "aas" && key == "shortcut")
	{
		node.shortcut = read_shortcut(rd, a)!;
		return;
	}
	rd.skip_value()!;
}

<*
 The first chord of a shortcut (`aas`: a list of chords, each a list of keys), with its keys joined.
 Further chords are skipped: a menu shows one.
*>
fn String? read_shortcut(Reader* rd, Allocator a)
{
	rd.begin_array()!;
	List{String} keys;
	keys.init(a, 4);
	bool taken = false;
	while (rd.has_more())
	{
		if (taken)
		{
			rd.skip_value()!;
			continue;
		}
		rd.begin_array()!;
		while (rd.has_more()) keys.push(rd.read_string()!);
		rd.end_array()!;
		taken = true;
	}
	rd.end_array()!;
	return join(keys.array_view(), a);
}

// The strings joined with SHORTCUT_SEPARATOR, in `a`.
fn String join(String[] parts, Allocator a)
{
	if (parts.len == 0) return "";
	usz total = (usz)parts.len - 1;
	for (sz i = 0; i < parts.len; i++) total += (usz)parts[i].len;
	char[] out = alloc::new_array(a, char, (sz)total);
	usz at     = 0;
	for (sz i = 0; i < parts.len; i++)
	{
		if (i > 0)
		{
			out[at++] = SHORTCUT_SEPARATOR[0];
		}
		mem::copy(&out[at], parts[i].ptr, (usz)parts[i].len);
		at += (usz)parts[i].len;
	}
	return (String)out;
}

<* The number of nodes in the tree below `node`, `node` included. *>
fn usz count_nodes(MenuNode* node)
{
	usz total = 1;
	for (sz i = 0; i < node.children.len; i++) total += count_nodes(&node.children[i]);
	return total;
}

<*
 The tree as the snapshot's flat menu: breadth first, the root first. Each entry's children are
 `menu[first_child .. first_child + child_count]`. Strings are copied into `a`.
*>
fn MenuItem[] copy_menu(MenuNode* root, Allocator a)
{
	usz total              = count_nodes(root);
	tray::MenuItem[] items = alloc::new_array(a, tray::MenuItem, (sz)total);
	@pool()
	{
		MenuNode*[] queue = alloc::new_array(tmem, MenuNode*, (sz)total);
		queue[0] = root;
		usz head = 0;
		usz tail = 1;
		while (head < tail)
		{
			MenuNode* node = queue[head];
			items[head] = menu_entry(node, a, tail);
			for (sz i = 0; i < node.children.len; i++) queue[tail++] = &node.children[i];
			head++;
		}
	};
	return items;
}

// The flat form of one node. `first_child` is where its children will be queued: the next free slot.
fn tray::MenuItem menu_entry(MenuNode* node, Allocator a, usz first_child)
{
	return {
		.id = node.id,
		.is_separator = node.is_separator,
		.label = convert::copy_text(node.label, a),
		.enabled = node.enabled,
		.visible = node.visible,
		.icon_name = convert::copy_text(node.icon_name, a),
		.shortcut = convert::copy_text(node.shortcut, a),
		.toggle = node.toggle,
		.toggle_state = node.toggle_state,
		.has_submenu = node.has_submenu,
		.submenu_loaded = !node.has_submenu || node.children.len > 0,
		.disposition = node.disposition,
		.first_child = node.children.len > 0 ? (uint)first_child : 0,
		.child_count = (uint)node.children.len,
	};
}

<*
 The user opened submenu `menu_id`: ask the application whether it changed, and read its children
 when it did or when they were never read.

 @return "true when the menu was read again"
 @return? error::INVALID_ARGUMENT : "No entry of the menu has this id"
*>
fn bool? open_submenu(SniBackend* b, ItemRecord* r, int menu_id)
{
	MenuNode* node = find_node(&r.menu, menu_id);
	if (node == null) return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no menu entry %d", menu_id)~;
	if (!node.has_submenu) return false;
	bool loaded  = node.children.len > 0;
	bool changed = (call_about_to_show(b, r, menu_id)) ?? false;
	if (loaded && !changed) return false;
	reload_menu(b, r, menu_id)!;
	b.dirty = true;
	return true;
}