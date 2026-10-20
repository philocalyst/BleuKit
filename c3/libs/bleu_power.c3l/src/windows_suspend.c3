<*
 SetSuspendState (powrprof.dll). Signature from windows-sys 0.59.0
 (`System/Power/mod.rs`); the semantics are the ones the research read on
 Microsoft Learn (docs/research/battery_power.md, V48): `bHibernate` FALSE
 suspends, and `bForce` has no effect.
*>
module bleu::power::windows_suspend @feat(WIN32) @link("powrprof");

<* BOOLEAN is one byte; the function returns zero on failure. *>
extern fn char setSuspendState(char hibernate, char force, char wakeup_events_disabled) @cname("SetSuspendState");