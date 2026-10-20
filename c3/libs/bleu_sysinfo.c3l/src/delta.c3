<*
 Turning two readings of a cumulative counter into a rate or a share.

 Every number the service publishes that is "per second" or "percent" comes
 from here, so there is one place to check the arithmetic. The functions are
 pure: the caller passes the elapsed time it measured, never the nominal
 sampling interval, so a late tick does not inflate a rate.
*>
module bleu::sysinfo::delta;
import std::collections::maybe, std::time, bleu::sysinfo;

const double MICROSECONDS_PER_SECOND = 1_000_000.0;

<*
 Cumulative busy time and total time of a processor, in its own tick unit.
 `busy` counts user, nice, system, irq and softirq time; `total` adds idle and
 iowait. Steal time is not counted, as in sysinfo (see the Linux reader).
*>
struct Ticks
{
	ulong busy;
	ulong total;
}

<*
 One processor's cumulative ticks at one reading. `index` is the processor number, -1 for the
 aggregate of all of them.
*>
struct CpuLine
{
	int index;
	Ticks ticks;
}

<* Cumulative byte counters of one network interface. Names are owned by whoever stores the counters. *>
struct NetCounters
{
	String name;
	ulong received;
	ulong sent;
}

<*
 A process's cumulative CPU time at one reading. `started` identifies the
 process (its start time in the same clock), so a recycled pid never inherits
 another process's history.
*>
struct ProcessTicks
{
	uint pid;
	ulong started;
	ulong ticks;
}

<*
 Share of one processor's time that was busy between two readings, in percent.
 Empty when no time passed or the counters went backwards (a hot-plugged core
 restarting its counters). Never zero for "unknown".

 @param before : "The earlier reading"
 @param now : "The later reading"
*>
fn Maybe{Percent} busy_percent(Ticks before, Ticks now)
{
	if (now.total <= before.total || now.busy < before.busy) return {};
	double share = (double)(now.busy - before.busy) / (double)(now.total - before.total);
	if (share > 1.0) share = 1.0;
	return maybe::value((Percent)(share * 100.0));
}

<*
 Bytes per second between two readings of a cumulative byte counter. Empty when
 no time passed or the counter went backwards (a wrap or a driver reset).

 @param elapsed : "Real time between the two readings, measured by the caller"
*>
fn Maybe{BytesPerSecond} byte_rate(ulong before, ulong now, Duration elapsed)
{
	if (elapsed <= time::DURATION_ZERO || now < before) return {};
	double seconds = (double)elapsed / MICROSECONDS_PER_SECOND;
	return maybe::value((BytesPerSecond)((double)(now - before) / seconds + 0.5));
}

<*
 A process's CPU share between two readings, in percent of one processor, the
 way `top` shows it. Clamped to `processors` at full speed. Empty when no time
 passed, the counter went backwards, or the tick unit is unknown.

 @param ticks_per_second : "Ticks of the process clock per second (USER_HZ on Linux, 10^7 for Windows 100 ns units)"
 @param processors : "Logical processors the system has"
*>
fn Maybe{Percent} process_percent(ulong ticks_before, ulong ticks_now, ulong ticks_per_second, Duration elapsed, uint processors)
{
	if (elapsed <= time::DURATION_ZERO || ticks_per_second == 0 || ticks_now < ticks_before) return {};
	double cpu_seconds = (double)(ticks_now - ticks_before) / (double)ticks_per_second;
	double share = cpu_seconds / ((double)elapsed / MICROSECONDS_PER_SECOND) * 100.0;
	double ceiling = (double)processors * 100.0;
	if (share > ceiling) share = ceiling;
	return maybe::value((Percent)share);
}

<*
 The earlier reading of the process `pid` if it is the same process (same start
 time), otherwise empty.
*>
fn ProcessTicks*? find_process(ProcessTicks[] earlier, uint pid, ulong started)
{
	foreach (&entry : earlier)
	{
		if (entry.pid == pid && entry.started == started) return entry;
	}
	return NOT_FOUND~;
}
