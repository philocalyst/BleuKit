<*
 The procfs backend: reads /proc and /sys on Linux every sampling period.

 Needs no daemon and no privilege. Command lines and owners of other users'
 processes may be unreadable; those fields are left empty, never guessed.
*>
module bleu::sysinfo::procfs @feat(LINUX);
import std::collections::list, std::time, bleu::availability, bleu::error, bleu::observe, bleu::rt::worker, bleu::sysinfo;

struct ProcfsBackend
{
	Allocator allocator;
	String root;
	Duration interval;
	uint process_count;
	List{delta::CpuLine} previous_cpu;
	List{delta::NetCounters} previous_net; // names are owned by `allocator`
	List{ProcessTicks} previous_processes;
}

const Driver DRIVER = {
	.info = { "procfs", "Linux /proc and /sys", 10 },
	.id = PROCFS,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

fn bool probe(Options* options)
{
	@pool()
	{
		return exists(string::tformat("%s/proc/stat", options.root));
	};
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	String root = options.root.copy(allocator);
	ProcfsBackend* backend = alloc::new(
		allocator,
		ProcfsBackend,
		{
			.allocator = allocator,
			.root = root,
			.interval = options.interval,
			.process_count = options.process_count,
		}
	);
	backend.previous_cpu.init(allocator);
	backend.previous_net.init(allocator);
	backend.previous_processes.init(allocator);
	@pool()
	{
		if (!exists(string::tformat("%s/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", root)))
		{
			capabilities.set(
				CPU_FREQUENCY,
				availability::no(HARDWARE_ABSENT, "no cpufreq driver exposes scaling_cur_freq")
			);
		}
		if (!exists(
			string::tformat("%s/sys/class/hwmon", root)
		) && !exists(string::tformat("%s/sys/class/thermal", root)))
		{
			capabilities.set(TEMPERATURES, availability::no(HARDWARE_ABSENT, "no hwmon or thermal sensors"));
		}
	};
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	ProcfsBackend* backend = (ProcfsBackend*)state;
	foreach (counters : backend.previous_net)
	{
		alloc::free(allocator, counters.name.ptr);
	}
	backend.previous_net.free();
	backend.previous_cpu.free();
	backend.previous_processes.free();
	alloc::free(allocator, backend.root.ptr);
	alloc::free(allocator, backend);
}

fn void run(void* state, SysinfoHub* hub, Host{Command}* host)
{
	ProcfsBackend* backend   = (ProcfsBackend*)state;
	sysinfo::Sampler sampler = { .reader = backend, .sample = &sample };
	sysinfo::run_sampler(&sampler, hub, host, backend.interval);
}