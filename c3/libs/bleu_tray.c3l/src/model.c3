<*
 System tray, as plain data: the tray items of other applications (Linux only), and
 our own tray icon with its menu (Linux, Windows and macOS).

 Every item is identified by `Item.id`, the bus name and object path joined the way the
 StatusNotifierWatcher reports them. Icons are RGBA bitmaps. Menus are a flat array whose
 children are contiguous, so a shell can draw them without recursion.
*>
module bleu::tray;
import bleu::availability, bleu::operation;

<* The item category from its `Category` property. `UNKNOWN` for any other text. *>
enum Category : char
{
	APPLICATION,
	COMMUNICATIONS,
	SYSTEM_SERVICES,
	HARDWARE,
	UNKNOWN,
}

<*
 The item status from its `Status` property. Text other than the three the specification
 names is read as `PASSIVE`.
*>
enum Status : char
{
	PASSIVE,
	ACTIVE,
	NEEDS_ATTENTION,
}

<* The check or radio mark a menu entry shows, from its `toggle-type` property. *>
enum Toggle : char
{
	NONE,
	CHECKMARK,
	RADIO,
}

<* The state of a checkable entry. `INDETERMINATE` is any value other than 0 or 1. *>
enum ToggleState : char
{
	OFF,
	ON,
	INDETERMINATE,
}

<* How urgent a menu entry is, from its `disposition` property. *>
enum Disposition : char
{
	NORMAL,
	INFORMATIVE,
	WARNING,
	ALERT,
}

<*
 One icon bitmap, RGBA, rows top to bottom, no padding: `pixels` holds exactly
 `width * height * 4` bytes, red first.
*>
struct Pixmap
{
	int width;
	int height;
	String pixels;
}

<*
 The tooltip of an item: an icon, a title and a description. The description may carry the
 specification's small markup subset; the caller decides how to show it.
*>
struct Tooltip
{
	String icon_name;
	Pixmap[] icon_pixmaps;
	String title;
	String description;
}

<*
 One entry of a menu. Entry 0 of `Item.menu` is the root (id 0, not shown). The children of
 entry `i` are `menu[first_child .. first_child + child_count]`, so the menu is a tree in an
 array. A submenu whose `submenu_loaded` is false has no children yet: call
 `Tray.open_submenu` before showing it.
*>
struct MenuItem
{
	int id;
	bool is_separator;
	String label; // mnemonic markers removed: "__" becomes "_", a single "_" is dropped
	bool enabled;
	bool visible;
	String icon_name;
	String shortcut; // the first chord of the entry's shortcut, joined with "+"; "" when none
	Toggle toggle;
	ToggleState toggle_state;
	bool has_submenu;
	bool submenu_loaded;
	Disposition disposition;
	uint first_child; // index of the first child; 0 when there are none
	uint child_count;
}

<*
 One tray item of another application, as read from its StatusNotifierItem properties.
 Strings and pixmaps belong to the snapshot that carries the item.
*>
struct Item
{
	String id; // bus name and object path, e.g. ":1.72/StatusNotifierItem"; stable for the item's life
	String bus_name;
	String object_path;
	String item_id; // the application's own name for the item (the `Id` property)
	String title;
	Category category;
	Status status;
	String icon_name;
	String icon_theme_path;
	Pixmap[] icon_pixmaps; // used when `icon_name` is empty or not found
	String attention_icon_name; // shown while `status` is NEEDS_ATTENTION
	Pixmap[] attention_icon_pixmaps;
	String overlay_icon_name;
	Pixmap[] overlay_icon_pixmaps;
	bool has_tooltip;
	Tooltip tooltip;
	bool item_is_menu; // true: a primary click should open the menu rather than activate
	String menu_path; // "" when the item has no menu
	uint menu_revision; // DBusMenu revision of `menu`
	MenuItem[] menu; // empty when no menu was read
}

<*
 The state of the tray. The watcher fields describe the session bus; the item list is what
 other applications registered with the watcher (or with us, when we are the watcher).
*>
struct State
{
	bool watcher_present; // some process owns the StatusNotifierWatcher name
	bool watcher_served; // this process is the watcher
	bool host_registered; // this process is registered as a host
	bool own_published; // our own icon is registered (Linux) or shown (Windows, macOS)
	Item[] items;
}

<*
 What the backend can do. Each value is `YES` or the reason it cannot be done.
 `HOST` is UNSUPPORTED_OS on Windows and macOS, which have no public tray host API.
*>
enum Cap : char
{
	HOST,             // list the tray items of other applications
	ACTIVATE,         // Activate, SecondaryActivate, ContextMenu and Scroll on another item
	MENU,             // read the menu of another item
	MENU_CLICK,       // send a click on a menu entry of another item
	PUBLISH_OWN_ICON, // show our own tray icon
	OWN_MENU,         // show the menu of our own icon
}

<*
 A transient: something happened. Read `Tray.latest` for the state it changed.
 `menu_id` is set for MENU_CLICKED, and `x` and `y` for the own-icon activations.
*>
enum EventKind : char
{
	ITEM_ADDED,
	ITEM_REMOVED,
	ITEM_CHANGED,
	MENU_CHANGED,
	OWN_ACTIVATED,
	OWN_SECONDARY_ACTIVATED,
	OWN_MENU_CLICKED,
}

<*
 A transient event; see `EventKind`. `item_id` names the tray item the event concerns, and is ""
 for the events of our own icon and its menu (the process has one icon of its own).
*>
struct Event
{
	EventKind kind;
	String item_id;
	int menu_id;
	int x;
	int y;
}

<* One entry of the menu of our own icon. Ids must be unique and greater than 0. *>
struct OwnMenuEntry
{
	int id;
	String label; // "_" marks a mnemonic, as in the specification; the shell draws it
	bool is_separator;
	bool enabled;
}

<*
 Our own tray icon. Its meaning per platform:
 - Linux: `icon` is an icon-theme name, shown through the item's IconName.
 - Windows: `icon` is the path of an .ico file; `title` is the tooltip.
 - macOS: `icon` is the path of an image file, shown in the menu bar; `title` is the tooltip,
 and the title shown when the image cannot be loaded.
*>
struct OwnItem
{
	String title;
	String icon;
	OwnMenuEntry[] menu;
}

<* Which concrete mechanism provides the tray. *>
enum Backend : char
{
	AUTO,
	SNI,    // Linux: StatusNotifierWatcher and StatusNotifierItem over the session bus
	WIN32,  // Windows: Shell_NotifyIconW
	APPKIT, // macOS: NSStatusItem
}

<*
 How `open` behaves. `publish_own` shows `own` as our tray icon, once the backend can.
 `own` is copied: the caller's strings and arrays need only live for the call.
*>
struct Options
{
	Backend backend; // AUTO tries the platform's backend
	bool publish_own;
	OwnItem own;
}

<* What a command does. The item it names is in `Command.item_id`. *>
enum CommandKind : char
{
	ACTIVATE,           // primary click at (x, y)
	SECONDARY_ACTIVATE, // middle click at (x, y)
	CONTEXT_MENU,       // right click at (x, y)
	SCROLL,             // wheel: `delta` steps, horizontal when `horizontal`
	OPEN_SUBMENU,       // read the children of submenu `menu_id` (AboutToShow)
	CLICK_MENU,         // click entry `menu_id`
	REFRESH,            // re-read every item now
	OWN_MENU_CLICK,     // entry `menu_id` of our own menu was chosen; posted by the macOS menu callback only
}

alias CommandOp = Operation{bool};

<*
 A request to the worker. `item_id` is a copy the worker frees after running the command.
 `op` is completed by the worker; it is null for REFRESH.
*>
struct Command
{
	CommandKind kind;
	String item_id;
	int x;
	int y;
	int delta;
	bool horizontal;
	int menu_id;
	CommandOp* op;
}