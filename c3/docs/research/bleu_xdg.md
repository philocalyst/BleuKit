# bleu_xdg: sources and binding decisions

Sources were fetched on 2026-10-20 from the URLs below (`main` branches for GLib and
GTK; the specification HTML at `specifications.freedesktop.org/<name>/latest/`). Line
numbers refer to those fetches. "Verified by test" means a unit test in the library
fails if the rule is broken.

## 1. Base Directory (`bleu::xdg::dirs`)

Primary: XDG Base Directory Specification, "Environment variables" section
(https://specifications.freedesktop.org/basedir-spec/latest/).

| Rule | Spec | GLib cross-check (`glib/gutils.c`) | Test |
| --- | --- | --- | --- |
| `XDG_DATA_HOME` default `$HOME/.local/share`; `XDG_CONFIG_HOME` `$HOME/.config`; cache `.cache`; state `.local/state` | "If ... not set or empty, a default equal to ..." | lines 1962-1975, 2027-2040 use the same defaults | `defaults_come_from_home` |
| Empty variable means unset | same | `data_dir_env && data_dir_env[0]` (1962-1966) | `empty_variables_mean_unset` |
| Relative paths are ignored | "must be absolute ... consider the path invalid and ignore it" | **Differs**: GLib accepts a relative `XDG_*_HOME` (no absolute check). This module follows the spec. | `relative_variables_are_ignored` |
| `XDG_DATA_DIRS` default `/usr/local/share/:/usr/share/`; `XDG_CONFIG_DIRS` default `/etc/xdg` | "should be used" | `data_dirs = "/usr/local/share/:/usr/share/"` (2690); config dirs default in the same table | `data_dirs_default_and_filtering`, `config_dirs_default_is_etc_xdg` |
| `XDG_RUNTIME_DIR` has no default; the caller decides on a fallback | "should fall back to a replacement directory" | not a GLib API | `runtime_dir_has_no_default` |
| Home fallback to `%USERPROFILE%` and drive-letter absolute paths | not in the spec | **Differs**: GLib uses `LocalAppData` on Windows. Documented in `dirs.c3`. | `userprofile_is_the_windows_home_fallback` |

Not checked: `XDG_RUNTIME_DIR` ownership and mode 0700 (needs `stat`).

## 2. Key files (`bleu::xdg::keyfile`)

Primary: Desktop Entry Specification 1.5 (https://specifications.freedesktop.org/desktop-entry-spec/latest/),
sections "Basic format", "Entries", "Value types", "Localized values for keys", "Locale matching".
The text was extracted from the spec XML (`desktop-entry-spec.xml`, gitlab.freedesktop.org/xdg/xdg-specs).

| Rule | Spec | GLib cross-check (`glib/gkeyfile.c`) | Test |
| --- | --- | --- | --- |
| Escapes `\s \n \t \r \\` | "Value types", string | `case 's'`...`case '\\'` (4716-4730) | `string_escapes_are_decoded` |
| Other escapes are an error; a trailing backslash is an error | not stated | "invalid escape sequence" and "escape character at end of line" (4716-4770) | `invalid_escapes_are_rejected_with_their_line` |
| Lists split on unescaped `;`; `a;;` has two elements; `\;` is literal | "Value types", string(s) | list mode of `g_key_file_parse_value_as_string` (`pieces`, lines 2410-2470) | `lists_split_on_unescaped_semicolons` |
| Key names `A-Za-z0-9-` | "Entries" | **Differs**: GLib accepts any name except `=`, `[`, `]` (4584-4600, comment: "gnome-vfs uses mime-types as keys"). Used for `mimeapps.list`/`mimeinfo.cache` via `KeySyntax.PERMISSIVE`. | `permissive_keys_accept_mime_types`, `duplicates_and_structure_are_rejected` |
| `\;` allowed in every value | list-only in spec | **Differs**: GLib refuses `\;` outside lists. This module accepts it (documented leniency). | none (documented) |
| Duplicate groups and keys are errors | "Basic format" | not checked against GLib | `duplicates_and_structure_are_rejected` |
| Locale order `lang_COUNTRY@MODIFIER`, `lang_COUNTRY`, `lang@MODIFIER`, `lang`, default | "Locale matching" table | not checked | `localized_values_follow_the_specification_order`, `modifier_is_not_matched_when_the_locale_has_none` |
| UTF-8 BOM and CRLF | "Basic format" (UTF-8) | no BOM handling found in `gkeyfile.c`: a BOM is accepted here beyond GLib | `utf8_bom_and_crlf_are_accepted` |

## 3. Desktop entries and Exec (`bleu::xdg::desktop_entry`, `bleu::xdg::exec`)

Primary: Desktop Entry Specification 1.5, sections "Desktop File ID", "OnlyShowIn, NotShowIn",
"The Exec key", "Application actions".

- Desktop file ID: `applications/foo/bar.desktop` → `foo-bar.desktop`; first in `$XDG_DATA_DIRS` wins (`scan`). Verified by `scan_applies_precedence_and_ids`.
- `OnlyShowIn`/`NotShowIn`: the first desktop name in `$XDG_CURRENT_DESKTOP` that appears in either list decides; otherwise shown unless `OnlyShowIn` is present. Verified by `show_in_follows_only_and_not_lists`.
- Exec quoting: spec examples (`\\\\` four backslashes in a file → one after both unescapes; `\\$` → `$`). Verified by `a_quoted_backslash_is_one_backslash`, `quoting_groups_words_and_undoes_escapes`.
- Field codes (`%f %u %F %U %i %c %k`, `%%`, deprecated `%d %D %n %N %v %m` removed, at most one of `%f %u %F %U`, `%i %F %U` standing alone, field codes not inside quotes). Verified by `exec_test.c3`.

Cross-check, `gio/gdesktopappinfo.c` (https://github.com/GNOME/glib/blob/main/gio/gdesktopappinfo.c):
`expand_macro` cases (2661-2700) and `expand_application_parameters` (2708-2745).

| Behaviour | Spec | GLib | This module |
| --- | --- | --- | --- |
| `%%` | literal `%` | `'%'` (2700s) | literal `%` |
| `%i` | `--icon <Icon>` or nothing | `--icon` + quoted name (2661-2670) | same |
| `%c`, `%k` | translated name, location | 2671-2690 | same |
| deprecated codes | removed | `case 'm': /* deprecated */ break;` (2689); `d` and `n` expand like `%f`, `D` like `%F` (2619-2640) | removed (spec) |
| unknown code | invalid, must not be processed | `default:` does nothing: silently dropped | **refused** (spec) |
| no file code | spec: remove codes, run once | appends `%f` ("This is also what KDE does") | **not done** (spec) |
| expanded text | never re-split | re-parsed with `g_shell_parse_argv` | split first, values inserted (spec) |

Desktop-entry lookup order: GLib's `desktop_file_dir` handling in `gdesktopappinfo.c` was read; it
was not run against this module.

## 4. Icon themes (`bleu::xdg::icon`)

Primary: Icon Theme Specification 0.13 (https://specifications.freedesktop.org/icon-theme-spec/latest/),
sections 3 (directory layout), 4 (keys and defaults), 5 (`FindIcon`, `LookupIcon`, `DirectoryMatchesSize`,
`DirectorySizeDistance`).

Second source: GTK `gtk/gtkicontheme.c` (https://github.com/GNOME/gtk/blob/main/gtk/gtkicontheme.c):

- `theme_dir_size_difference` (2715-2750): Fixed `|size*scale - Size*Scale|`; Threshold bounds
  `(Size - Threshold)*Scale` and `(Size + Threshold)*Scale`; Scalable bounds `MinSize*Scale`,
  `MaxSize*Scale`.
- Defaults (3147-3186): `Type` defaults to Threshold (3156), `Scale` 1, `Threshold` 2,
  `MinSize`/`MaxSize` default to `Size`.

Decisions:

- The spec pseudocode's Threshold distance has two typos (`iconsize*iconsize`; the lower bound
  uses `MinSize`). This module uses the bounds above, which GTK also uses. Verified by
  `threshold_matching_and_distance` (distance 44 for scale 2 at 48 px).
- GTK's Scalable branch compares the unscaled size with `MaxSize*Scale` (2733). This module
  compares the scaled size, as the spec's formula does. Not covered by a GTK-equivalence test.
- Lookup order: the user's theme, its parents depth-first, then `hicolor` and its parents, then
  the unthemed fallback in each base directory. Verified by `lookup_follows_the_specification`.
- Closest match: strictly smaller distance wins; ties keep the earlier directory. Verified by
  `closest_size_is_used_when_no_directory_matches`.
- Lists in `index.theme` are comma-separated (spec section 4). Verified by `index_defaults_and_types`.
- Default base directories: `$HOME/.icons`, `$XDG_DATA_DIRS/icons`, `/usr/share/pixmaps`
  (spec section 3). `$XDG_DATA_HOME/icons` is not included, as the spec omits it.
- Inheritance is depth-limited (16), so a cycle terminates. Verified by
  `absolute_names_and_inheritance_loops_are_handled`.

## 5. MIME associations (`bleu::xdg::mime`)

Primary: Association between MIME types and applications
(https://specifications.freedesktop.org/mime-apps-spec/latest/): "File name and location"
(the eight-location lookup order, including `$desktop-mimeapps.list`), "Adding/removing
associations" (the suggested algorithm), "Default Application".

Second source: GLib `gio/gdesktopappinfo.c` lines 1036-1041 read `mimeinfo.cache` as a
`[MIME Cache]` group through the same mimeapps reader, which is the layout this module
reads. Verified by `mimeinfo_cache_lists_applications`.

Decisions:

- Desktop-specific files only supply defaults (the spec: they "can only be used for specifying the
  default application"). Verified by `defaults_follow_desktop_specific_then_generic_files`.
- A desktop file in a data directory is blacklisted after it is seen, so the higher-precedence
  copy hides the lower one. Verified by `associations_add_scan_and_remove` (`a.desktop` appears
  once although `sys/applications` also has it).
- A default is used only if its desktop file exists and is associated; otherwise the first
  associated application. Verified by `default_falls_back_to_the_first_association`.
- Not done: the specific-to-generic loop over MIME type hierarchies (needs shared-mime-info).

## 6. Trash

Not written. The brief allowed skipping it rather than doing it poorly.
