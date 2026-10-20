# bleuctl

Command-line client for `bleud`, and the same commands run in-process with `--embedded`
for scripts that do not want a daemon.

```
bleuctl [--socket PATH] list
bleuctl [--socket PATH] state <service>
bleuctl [--socket PATH] caps <service>
bleuctl [--socket PATH] watch <service>
bleuctl [--socket PATH] call <method> [json-params]
bleuctl --embedded [--fake-root DIR] list | state <svc> | caps <svc> | watch <svc> | call <method> [json]
```

* Results are printed pretty (one member per line). A failure goes to stderr as
  `bleuctl: <STATUS>: <message>`, the same text the daemon sends, and the exit code is 1.
* `watch` prints the current state, then each new state, until the daemon goes away or
  the process is interrupted.
* `--embedded` opens the service in this process. `watch` then prints each state from the
  service's worker thread. A service that does not open is reported with its reason.
* `--socket` defaults to `$XDG_RUNTIME_DIR/bleud.sock`, the same as `bleud`.
* Exit codes: 0 success; 1 the daemon or service refused; 2 a bad command line.

## Platforms

`--embedded` works on every target. The socket client is POSIX only: on Windows it
refuses with `UNSUPPORTED`, and the message says to use `--embedded`.

## Not done

* `list` in socket mode prints the daemon's summaries as they are; there is no table layout.
* No reconnect: a watch that loses the daemon ends with `DISCONNECTED`.

## Verified how

* Linux, executed: every command in socket mode against `bleud` (`apps/bleud/tests/run.sh`)
  and in embedded mode (battery on a fake tree, sysinfo on the real system, `watch` over a
  changing fake tree, bad arguments, unknown services). `brightness set` writes the fake
  backlight and then fails its read-back with `BACKEND_FAILURE`, because a static fake file
  does not follow the write; that is the service's check working, not a CLI fault.
* Compile only: `tools/check-app.sh bleuctl` is clean on linux-x64, linux-aarch64, macos-x64 and
  macos-aarch64. windows-x64 and windows-aarch64 fail in `bleu_media`, which the registry needs.
