# Adversarial review checklist

You are a reviewer, not the author. Your job is to FIND DEFECTS the author and
their tests missed, and to prove them. A review that finds nothing in 3,000
lines is almost certainly a bad review: look harder (but never invent).

Method
1. Read the library's README (claims!), then every source file, then the tests.
   Compare what the README/docs claim against what the code does.
2. For every finding, produce EVIDENCE: a failing test or scratch program you
   actually ran (put scratch code in your private temp dir, never in `libs/`),
   or a precise code path with file:line and the concrete input/state that
   breaks it. Unproven suspicions go in a separate "Suspicions" list.
3. Verify the author's cited facts you doubt against the primary source (the
   hosts listed in docs/STYLE.md are reachable).
4. Do NOT edit library code. Write ONLY `docs/reviews/<lib>.md`.

Look specifically for
* **Correctness vs sources**: wrong constants/struct layouts/vtable slots/opcodes,
  wrong units or sign conventions, off-by-one in framing/padding/checksums.
* **Error handling**: swallowed errors (`if (catch x) {}` without reason), `!!`
  on I/O or untrusted data (would abort the process), faults mapped to the wrong
  class, lost `error::last()` detail, success reported when the operation was
  only queued, optionals unwrapped without checks.
* **Resources**: every fd/HANDLE/COM pointer/CFTypeRef/allocation released on ALL
  paths (early returns, errors, shutdown); leaks in worker exit; double close;
  use-after-free of snapshot/arena memory; temp-allocator (`tmem`) pointers that
  escape a `@pool`.
* **Concurrency**: shared state touched from two threads without a lock; callbacks
  from foreign threads doing more than enqueue; blocking calls under a lock;
  lock-order inversions; listener re-entrancy; shutdown races (stop while a
  command is in flight; operations never completed → waiters hang forever).
* **Untrusted input**: unbounded allocations from peer-supplied lengths, integer
  overflow in size arithmetic, missing bounds checks, non-UTF-8 text assumed
  UTF-8, path/command injection in anything spawned or written to sysfs.
* **Contract drift**: deviations from docs/ARCHITECTURE.md and
  docs/SERVICE_TEMPLATE.md (plain-data state, publish-whole-snapshot,
  capabilities honest, no silent fallbacks), `Cap`s that claim YES but the code
  returns UNSUPPORTED (or the reverse), README coverage matrix claims not backed
  by code or tests.
* **Quality**: dead code, copy-paste duplicates that should be shared, magic
  numbers without a cited source, misleading names, missing doc comments on
  public items, overly long functions, non-idiomatic C3.
* **Tests**: what is NOT tested that matters; tests that cannot fail (assert
  true, no assertion on the behaviour), flaky timing assumptions.

Run what exists: `tools/check.sh <lib deps>` (all six targets) and the lib's
tests (use `--libdir "$(tools/libdir.sh)"`, a private cwd, `compile-test -o`,
and `timeout`). Report failures you see.

Output format of docs/reviews/<lib>.md
  # Review of <lib>
  Verdict (3 lines), then a table: ID | Severity (CRITICAL/HIGH/MEDIUM/LOW) |
  Where (file:line) | Defect | Evidence (how you proved it) | Suggested fix.
  Then "Suspicions (unproven)", then "What is good" (briefly, to calibrate),
  then "Tests run and results".
Final message to the lead: under 20 lines — counts per severity and the top 5.
