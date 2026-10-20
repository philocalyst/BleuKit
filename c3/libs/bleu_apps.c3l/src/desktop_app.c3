module bleu::apps;
import bleu::xdg::desktop_entry, bleu::xdg::exec, bleu::error;

<*
 Whether a parsed desktop entry is an application the catalogue lists: an
 `Application` that is not `Hidden` and is shown in the current desktops.
 `NoDisplay` entries are listed (see `App.no_display`).

 @param current_desktops : "The names in `XDG_CURRENT_DESKTOP`, in order"
*>
fn bool lists_entry(DesktopEntry* entry, String[] current_desktops)
{
	return entry.type == desktop_entry::EntryType.APPLICATION && !entry.hidden && entry.show_in(current_desktops);
}

<*
 Build the `App` for a listed desktop entry. Every string is copied into
 `allocator`, so the entry may be released afterwards.

 @param id : "The desktop file ID, for example org.example.Editor.desktop"
 @param location : "The file the entry was read from"
 @param [&inout] allocator : "Allocator for the strings and arrays of the app"
*>
fn App desktop_app(DesktopEntry* entry, String id, String location, Allocator allocator)
{
	AppAction[] actions = alloc::new_array(allocator, AppAction, entry.actions.len);
	foreach (i, action : entry.actions)
	{
		actions[i] = { .id = action.id.copy(allocator), .name = action.name.copy(allocator), .icon = action.icon.copy(allocator), .exec = action.exec.copy(allocator) };
	}
	return {
		.id = id.copy(allocator),
		.name = entry.name.copy(allocator),
		.generic_name = entry.generic_name.copy(allocator),
		.comment = entry.comment.copy(allocator),
		.keywords = copy_strings(allocator, entry.keywords),
		.categories = copy_strings(allocator, entry.categories),
		.icon = entry.icon.copy(allocator),
		.launch = AppLaunchKind.EXEC,
		.target = entry.exec.copy(allocator),
		.location = location.copy(allocator),
		.terminal = entry.terminal,
		.no_display = entry.no_display,
		.dbus_activatable = entry.dbus_activatable,
		.startup_notify = entry.startup_notify,
		.startup_wm_class = entry.startup_wm_class.copy(allocator),
		.bundle_id = "",
		.actions = actions,
		.mime_types = copy_strings(allocator, entry.mime_types),
	};
}

<*
 The desktop file ID without its `.desktop` suffix: the D-Bus well-known name
 of a D-Bus-activatable app. Returns `id` unchanged when it has no suffix.
*>
fn String desktop_id_stem(String id)
{
	if (!id.ends_with(".desktop")) return id;
	return id[0:id.len - ".desktop".len];
}
