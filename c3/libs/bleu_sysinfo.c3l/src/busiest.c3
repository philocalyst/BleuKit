<*
 Ordering of the process list: busiest first, so the list can be cut to the
 top N. Pure, so the order is tested without a live system.
*>
module bleu::sysinfo::busiest;
import bleu::sysinfo;

<*
 True when `a` belongs before `b`: a known CPU share beats an unknown one, a
 larger share beats a smaller one, and equal shares are ordered by pid.
*>
fn bool precedes(Process* a, Process* b)
{
	if (a.cpu.has_value != b.cpu.has_value) return a.cpu.has_value;
	if (a.cpu.has_value && a.cpu.value != b.cpu.value) return a.cpu.value > b.cpu.value;
	return a.pid < b.pid;
}

<* Sort `processes` in place into the order `precedes` defines. Insertion sort: process lists are a few hundred long. *>
fn void sort_busiest(Process[] processes)
{
	for (sz i = 1; i < processes.len; i++)
	{
		Process key = processes[i];
		sz j        = i - 1;
		while (j >= 0 && precedes(&key, &processes[j]))
		{
			processes[j + 1] = processes[j];
			j--;
		}
		processes[j + 1] = key;
	}
}