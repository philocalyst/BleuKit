# dmsd

DankMaterialShell's Go `core` server, rebuilt on Bleu. The unmodified DMS QML shell
connects to dmsd's socket and speaks DMS's line-JSON protocol. Reference, coverage and
the module recipe: [`docs/DMSD.md`](../../docs/DMSD.md).

Status: the core and two modules (`brightness`, `loginctl`) are done. Every other DMS
module is not started yet, and its methods answer `unknown method`.

## Build and run

    tools/check-apps.sh dmsd              # type-check for the POSIX targets (Windows is skipped)
    apps/dmsd/tests/run.sh                # the end-to-end suite (needs dbus-daemon, python3, dbus-next)

    dmsd [--socket PATH] [--fake-root DIR] [--module-off NAME]... [--debug]

dmsd is POSIX-only: it uses signals, pipes and Unix sockets through `bleu_ipc`.

## Layout

    project.json           the executable target and its library closure (every dependency, listed)
    src/main.c3            arguments, signals, start, serve, stop
    src/module.c3          the Module contract, Context, StatePump
    src/capabilities.c3    handshake capability names
    src/server_methods.c3  getServerInfo, shell.ready
    src/dms_json.c3        JSON lines, SuccessResult
    src/params.c3          request parameters (dankgo's error texts)
    src/brightness_math.c3 DMS's brightness formulas; brightness_math_test.c3 holds their @tests
    src/mod_brightness.c3  brightness module
    src/mod_loginctl.c3    loginctl module (session, inhibitor, sleep barrier)
    tests/run.sh           end-to-end: build, unit tests, protocol, sleep barrier, shutdown
    tests/check_dms.py     drives dmsd as the DMS shell does and checks every reply
    tests/dmsclient.py     the client (two connections, id scheme, frame dispatch)
    tests/mock_logind.py   dbus-next stand-in for org.freedesktop.login1
    tests/extract_go_tags.py  the Go json tags of the DMS structs, from a DMS checkout
    tests/golden/          expected replies and the Go tag list

## Notes for whoever touches it

* A `Module` descriptor is a `const` global. A descriptor built in a function returns slices
  that point at the function's frame; the daemon then sends garbage in the handshake. This was
  found by test.
* Module variables cannot be named `module` (a C3 keyword).
* Request parameters are read with `params::`, not with `bleu::json::read`, so the error texts are
  dankgo's. A number is read as float64 and truncated, as Go does.
* The shell's `subscribe` is served by bleu_ipc. `<module>.subscribe` methods answer
  `not supported`, because a method reply cannot stream.
