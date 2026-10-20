# dmsd

DankMaterialShell's Go `core` server, rebuilt on Bleu. The unmodified DMS QML shell
connects to dmsd's socket and speaks DMS's line-JSON protocol. Reference, coverage and
the module recipe: [`docs/DMSD.md`](../../docs/DMSD.md).

Status (from [`docs/DMSD.md`](../../docs/DMSD.md), "Status at a glance"):

* Done: the socket, handshake, framing, `ping`, `subscribe`, `unsubscribe`, `getServerInfo`,
  `shell.ready`; the modules `brightness`, `loginctl`, `bluetooth`, `network`, `clipboard`,
  `apps` (partial), `dgop` (partial), `wlroutput`, `gamma`, `theme.auto` with `matugen.status`,
  and `freedesktop` (partial).
* Refused: `evdev`; the refused modules (cups, tailscale, wellbeing, sysupdate, wallpaper,
  files, plugins, themes, registries) answer `not supported`.
* Not started: `location`, `dbus`, `notify`. Their methods answer `unknown method`.
* Tested on Linux only. The `clipboard` module is compiled but only its absence is run.
  No real compositor, DMS shell or BlueZ/NetworkManager daemon was used: each test runs
  against a fake or mock.

## Build and run

    tools/check-apps.sh dmsd              # type-check for the POSIX targets (Windows is skipped)
    apps/dmsd/tests/run.sh                # the end-to-end suite (needs dbus-daemon, python3, dbus-next)

    dmsd [--socket PATH] [--fake-root DIR] [--module-off NAME]... [--debug]

dmsd is POSIX-only: it uses signals, pipes and Unix sockets through `bleu_ipc`.

## Layout

    project.json                 the executable target and its library closure (every dependency, listed)
    src/main.c3                  arguments, signals (self-pipe), start modules, serve, stop in reverse order
    src/module.c3                Module contract, Context, StatePump (state to topic, own thread)
    src/capabilities.c3          capability names of the started modules, for the handshake
    src/server_methods.c3        getServerInfo, shell.ready
    src/dms_json.c3              JSON lines, SuccessResult, camelCase names by hand (module dmsd::wire)
    src/dms_wire_ext.c3          more DMS wire shapes: floats, nulls, Go's zero time (module dmsd::wire)
    src/params.c3                request parameters, read as dankgo's params package reads them
    src/param_lists.c3           array-valued parameters, read as dankgo's params.StringSlice reads them
    src/replies.c3               refused methods: each answers `not supported: <why>`
    src/brightness_math.c3       DMS's percent and raw-value formulas (pure)
    src/brightness_math_test.c3  @tests of the brightness arithmetic
    src/mod_brightness.c3        brightness module
    src/mod_loginctl.c3          loginctl module: session state, actions, sleep barrier
    src/mod_bluetooth.c3         bluetooth module: methods, state topic, pairing prompts
    src/bluetooth_wire.c3        bluetooth DMS shapes: state, device, adapter, prompt
    src/mod_network.c3           network module: state and prompt topics, method registration
    src/mod_network_state.c3     NetworkState, WiFiNetwork, WiFiDevice, EthernetDevice from a Bleu snapshot
    src/mod_network_actions.c3   Wi-Fi actions, network.info, passphrase answers
    src/mod_network_credentials.c3  network.credentials: the prompt event pump, CredentialPrompt
    src/mod_network_unsupported.c3  the refused network methods, one table
    src/mod_clipboard.c3         clipboard module (over bleu_clipboard)
    src/mod_apps.c3              apps module: apppicker, browser, mime
    src/mod_sysinfo.c3           dgop module: dgop.meta, dgop.modules over bleu_sysinfo
    src/mod_evdev.c3             evdev module: evdev.getState refused
    src/mod_unsupported.c3       the refused modules (cups, tailscale, ...), one table
    src/mod_wlroutput.c3         wlroutput module (over bleu_display)
    src/mod_gamma.c3             gamma module: night light (colour temperature on a schedule) on bleu_color
    src/mod_gamma_settings.c3    gamma settings (DMS's wayland.Config) and the one bleu_color command they become; pure
    src/mod_gamma_settings_test.c3  @tests of the clock values
    src/mod_theme_auto.c3        theme.auto module and matugen.status
    src/mod_theme_auto_calc.c3   civil calendar and sun model of theme.auto (pure)
    src/mod_theme_auto_calc_test.c3 @tests of the calendar and the sun model
    src/mod_freedesktop.c3       freedesktop module: colour scheme on bleu_appearance, screensaver state
    tests/run.sh                 the suite: builds dmsd, runs the unit tests, then each area below
    tests/check_dms.py           core: drives dmsd as the DMS shell does and checks every reply
    tests/bluetooth.sh           bluetooth module, against the BlueZ mock of bleu_bluetooth
    tests/bluetooth_check.py     its reply checks
    tests/modules.sh             dgop, apps, evdev, refusals, clipboard absence
    tests/check_modules.py       its reply checks
    tests/desktop.sh             wlroutput, gamma, theme.auto, freedesktop (fake wlr compositor, mock portal)
    tests/check_desktop.py       its reply checks
    tests/fake_wayland.py        fake Wayland compositor: wlr-output-management and wlr-gamma-control
    tests/mock_portal.py         xdg-desktop-portal mock on a private session bus
    tests/network.sh             network module, against the NetworkManager mock of bleu_network
    tests/network_check.py       its reply checks
    tests/mock_logind.py         dbus-next stand-in for org.freedesktop.login1
    tests/dmsclient.py           the client (two connections, id scheme, frame dispatch)
    tests/dms_reference.py       independent port of DMS's theme schedule and sun model, for checking dmsd
    tests/extract_go_tags.py     the Go json tags of the DMS structs, from a DMS checkout
    tests/golden/                expected replies and the Go tag lists
    tests/protocols/             the wlr protocol XML the fake compositor uses

## Notes for whoever touches it

* A `Module` descriptor is a `const` global. A descriptor built in a function returns slices
  that point at the function's frame; the daemon then sends garbage in the handshake. This was
  found by test.
* Module variables cannot be named `module` (a C3 keyword).
* Request parameters are read with `params::`, not with `bleu::json::read`, so the error texts are
  dankgo's. A number is read as float64 and truncated, as Go does.
* The shell's `subscribe` is served by bleu_ipc. `<module>.subscribe` methods answer
  `not supported`, because a method reply cannot stream.
