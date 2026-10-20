# Brief for service-implementation agents (extends AGENT_BRIEF.md)

Read, in order: `docs/AGENT_BRIEF.md`, `ARCHITECTURE.md`, `STYLE.md`,
`C3_GOTCHAS.md`, **`SERVICE_TEMPLATE.md`**, then every source file of
`libs/bleu_battery.c3l` (the reference service), `libs/bleu_service.c3l`
(the `Hub`), `libs/bleu_core.c3l`, and the README of each infrastructure
library you will use (`libs/bleu_rt`, `bleu_dbus`, `bleu_dl`, `bleu_objc`,
`bleu_win`, `bleu_ddc`, `bleu_xdg`, `bleu_plist` — check `ls libs`; a library
whose README is missing is unfinished: build what you can without it and finish
that part when it lands, re-checking `ls` before your final report).

Your research note in `docs/research/` is your spec: it lists the exact native
calls, constants, double-validated sources, pitfalls and the **v1 cut line**.
Implement the v1 cut; do not implement what it defers; do not re-research
unless a fact you need is marked UNVERIFIED (then verify it from primary
sources or mark the capability as such in code).

You own only `libs/bleu_<service>.c3l/**` (and `docs/research/<service>_impl.md`
for implementation notes: deviations from the research, what you verified).
Shared libraries (`bleu_core`, `bleu_rt`, `bleu_service`, infra) are read-only to
you: if they need a change, say so precisely in your final report.

Mandatory deliverables:
1. `model.c3`: strongly typed plain-data `State`, `Cap`, `Event`, `Command`,
   `Options`, `Backend` per the template. Revisit the research's draft model:
   fix anything that is not plain data; prefer enums and unit typedefs
   (`bleu::unit`: `Level`, `Gain`, `Dbm`, `Celsius`, `MilliWatt`, ...); use
   `Maybe{T}` for optional measurements.
2. `service.c3`, `driver.c3`, `probe.c3` exactly in the shape of `bleu_battery`.
   Commands that can fail or take time return `Operation{Value}*` (see
   `bleu_core/src/operation.c3`); show the caller-side usage in the README.
3. Backends for all three operating systems as far as the v1 cut says. Each
   backend: its own gated files, conversion/parsing in ungated pure files with
   `@test`s, `Capabilities` filled truthfully (an unsupported operation raises
   `error::UNSUPPORTED` and reports `UNSUPPORTED_*` — no silent no-ops).
4. Linux backends are RUN against fakes: a fake root directory for sysfs/procfs,
   or a private `dbus-daemon` with a Python mock service (pip works; use
   `dbus-next` in a venv in your scratch dir; keep the mock script in
   `libs/bleu_<service>.c3l/tests/` with a `run.sh`). Report real output.
   macOS and Windows are type-checked only (`tools/check.sh` on all six targets)
   and your README must say so plainly.
5. `README.md` in the lib: purpose, public API (20 lines), a coverage matrix
   (capability × OS × backend → Run / Compiled-only / Not done), and a "Not done"
   list.
6. `c3fmt -i` on your files; `tools/check.sh bleu_core bleu_rt bleu_service <deps> bleu_<service>`
   clean on all six targets; tests pass.

Hidden/private OS APIs (see ARCHITECTURE.md): resolve through `bleu::dl` at run
time, one `*_private.c3` file each with source citations, lower priority or a
separate `Cap`, off by default when the research says so.

Final message to the lead: under 40 lines — built, verified (commands + results),
not done/doubtful, changes needed in shared libs.
