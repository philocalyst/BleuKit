<*
 What every backend does with the raw counters once it has read them: turn
 processor ticks into cores, interface counters into rates, process records
 into the busiest-first list. Platform readers only produce the raw numbers.
*>
module bleu::sysinfo;
import std::collections::list, std::collections::maybe, std::time, bleu::sysinfo::delta, bleu::sysinfo::busiest;

<* A process as read in one sample, with the counters the next sample needs. *>
struct ProcessSample
{
	Process process;
	ProcessTicks ticks;
}

<* Number of logical processors in a /proc/stat-style list (the aggregate line is not one). *>
fn uint count_processors(delta::CpuLine[] lines)
{
	uint count = 0;
	foreach (&line : lines)
	{
		if (line.index >= 0) count++;
	}
	return count;
}

<*
 Fill the total and per-core usage of `cpu` from this sample's ticks and the
 previous sample's (`earlier`). Frequencies are left empty for the platform to
 fill. Empty usage for the first sample.
*>
fn void fill_cpu(Cpu* cpu, Allocator allocator, delta::CpuLine[] lines, delta::CpuLine[] earlier)
{
	cpu.cores = alloc::new_array(allocator, CpuCore, (sz)count_processors(lines));
	usz next = 0;
	foreach (&line : lines)
	{
		if (line.index < 0)
		{
			cpu.usage = usage_of(earlier, -1, line.ticks);
			continue;
		}
		cpu.cores[next] = {
			.name = string::tformat("cpu%d", line.index)
			.copy(allocator), .usage = usage_of(earlier, line.index, line.ticks), };
		next++;
	}
}

// The share of the processor `index` (-1 for all of them) that was busy since `earlier`.
fn Maybe{Percent} usage_of(delta::CpuLine[] earlier, int index, delta::Ticks now)
{
	foreach (&line : earlier)
	{
		if (line.index == index) return delta::busy_percent(line.ticks, now);
	}
	return { };
}

<* Subtraction for counters that may be out of order: never wraps below zero. *>
fn ulong sub_or_zero(ulong a, ulong b) @inline => a > b ? a - b : 0;

<*
 Rates since the previous sample, copied into `allocator`. An interface that is
 new in this sample has empty rates.
*>
fn NetInterface[] interface_rates(
	List{delta::NetCounters}* earlier,
	Allocator allocator,
	delta::NetCounters[] now,
	Duration elapsed
)
{
	NetInterface[] links = alloc::new_array(allocator, NetInterface, now.len);
	foreach (i, &counters : now)
	{
		NetInterface link = { .name = counters.name.copy(allocator) };
		if (try before = find_counters(earlier, counters.name))
		{
			link.receive = delta::byte_rate(before.received, counters.received, elapsed);
			link.transmit = delta::byte_rate(before.sent, counters.sent, elapsed);
		}
		links[i] = link;
	}
	return links;
}

fn delta::NetCounters*? find_counters(List{delta::NetCounters}* earlier, String name)
{
	foreach (&counters : earlier)
	{
		if (counters.name == name) return counters;
	}
	return NOT_FOUND~;
}

<*
 Keep `now` as the history for the next rate. Names of the old history are freed
 from `allocator`; the new ones are copied into it.
*>
fn void replace_counters(List{delta::NetCounters}* earlier, Allocator allocator, delta::NetCounters[] now)
{
	foreach (&counters : earlier)
	{
		alloc::free(allocator, counters.name.ptr);
	}
	earlier.clear();
	foreach (&counters : now)
	{
		earlier.push({ .name = counters.name.copy(allocator), .received = counters.received, .sent = counters.sent });
	}
}

<* The `count` busiest processes, copied into `allocator`, in the order `busiest::sort_busiest` defines. *>
fn Process[] top_processes(uint count, Allocator allocator, ProcessSample[] all)
{
	Process[] ordered = alloc::new_array(tmem, Process, all.len);
	foreach (i, &sampled : all)
	{
		ordered[i] = sampled.process;
	}
	busiest::sort_busiest(ordered);
	sz kept       = all.len < count ? all.len : (sz)count;
	Process[] top = alloc::new_array(allocator, Process, kept);
	for (sz i = 0; i < kept; i++)
	{
		Process p = ordered[i];
		top[i] = {
			.pid = p.pid,
			.name = p.name.copy(allocator),
			.command = p.command.copy(allocator),
			.user = p.user.copy(allocator),
			.cpu = p.cpu,
			.memory = p.memory,
		};
	}
	return top;
}