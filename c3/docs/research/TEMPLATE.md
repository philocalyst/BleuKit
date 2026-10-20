# Research note template (service spikes)

Every research spike writes `docs/research/<service>.md` with these sections.
Brevity with precision beats volume: an implementer must be able to code from
this file without re-reading the sources, and a reviewer must be able to verify
each claim from its citation.

## 1. What a shell needs
Bullet list of user-visible features this service must back (a bar widget, a
quick-settings tile, a settings panel, a lock screen ...), in priority order.

## 2. Per-platform native route (Linux / macOS / Windows)
For EACH platform and EACH feature: the API route(s) ranked by preference.
Per route give:
* **Interface**: exact names — D-Bus service/path/interface/member + signatures;
  C function names + header + library/framework; Obj-C class/selector; COM
  class/interface + IIDs; Wayland protocol + request/event names; sysfs paths.
* **Call sequence** for the happy path as numbered pseudocode, including
  event/notification registration and how to stop.
* **Data layouts & constants** needed (struct fields, enum values, flag bits),
  with the *value* written out.
* **Permissions / entitlements / daemons** (polkit actions, TCC prompts incl.
  location-services for Wi-Fi SSIDs, Info.plist keys, UAC, group membership).
* **Pitfalls** (threading/apartment rules, version differences, deprecated or
  removed API with the OS version it changed in, known bugs).
* **Private/undocumented** routes clearly marked, with OS versions observed.

## 3. Reference implementations (prove it works)
A table: project | language | file path (raw URL) | what to copy the idea of.
Include the best Rust crates (docs.rs / static.crates.io tarballs), and C/Go/
Swift implementations in Quickshell, DankMaterialShell, Astal, KDE Plasma
(plasma-nm, plasma-pa, powerdevil), GNOME shell, MonitorControl, Lunar,
Hammerspoon, Seelen UI, Zebar, Windows terminal/PowerToys, etc. where relevant.
State for each whether you *read the code* or only the README.

## 4. Double validation
For every non-obvious claim in section 2, list the two independent sources that
agree. Mark claims with only one source `(single-source)`. Mark anything you
could not verify `(UNVERIFIED)` — never present a guess as fact.

## 5. Proposed Bleu model
A draft of the platform-neutral C3 types in the style of docs/ARCHITECTURE.md:
`State` (plain data: structs/enums/typedef quantities/String/slices), `Cap`
enum (every optional operation), `Event` (transients), commands/operations with
their results, `Options`, and the backend list with priority per OS. Keep types
strong (`Level`, `Dbm`, `MilliWatt`, enums, ids as `String`). Note which fields
are unavailable on which platform.

## 6. Risks and cut lines
What is hard, what cannot be done on which OS without private API or admin
rights, and what you recommend leaving out of the first version.
