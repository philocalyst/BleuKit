# Brief for implementation agents

You are one of several engineers building **Bleu**, a desktop-service SDK in C3.
Work only inside the directories your task names. You are working in parallel
with others: do not touch other libraries, `docs/ARCHITECTURE.md`,
`docs/STYLE.md`, or `libs/bleu_core.c3l` (report problems with them to the
lead instead). Do not run `git commit`/`git push`; the lead commits.

Read first, in order:
1. `docs/ARCHITECTURE.md` – the design and the contract every service follows.
2. `docs/STYLE.md` – the verified C3 0.8.5 rules, quality bar, how to cite sources.
3. `docs/C3_GOTCHAS.md` – pitfalls already found (append yours).
4. `libs/bleu_core.c3l/src/*.c3` – the vocabulary you build on (read every file;
   they are short and are the model of the idiom and documentation level
   expected).

Quality bar: the lead reviews every line adversarially and will send work back.
Aim for code that needs no rework: strongly typed, `excuse`-based error
handling with `error::raise` context, `defer` for every resource, doc comments
on all public items, no magic numbers, no dead code, no pretend stubs.
Idiomatic C3: use `typedef`/`enum`/`constset`/`bitstruct`/generics/macros/
contracts where they make the code clearer, and the standard library
(`/opt/c3/c3/lib/std`) before writing your own.

Validate everything you cannot run: cite two independent primary sources for
each native layout/constant/sequence (see STYLE.md) and record them in
`docs/research/<lib>.md`.

Definition of done for a library:
* `tools/check.sh <your libs and their dependencies>` is clean on ALL six targets.
* Everything runnable on Linux was run (tests or a scratch program) and you
  report what you ran and what the output was.
* `libs/<lib>.c3l/README.md` says what it is, the public API in 20 lines, what
  is NOT done, and what was verified how (run / compiled-only).
* Files are `c3fmt`-clean.

Your final message to the lead must be SHORT (under 40 lines): what you built
(files, public API), what you verified and how, what is missing or doubtful,
and any problems in core or other libs. Do not paste code.
