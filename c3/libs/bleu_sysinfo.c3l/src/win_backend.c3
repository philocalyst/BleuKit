<*
 The Windows backend: NtQuerySystemInformation for processes and processor
 times, GlobalMemoryStatusEx for memory, the volume APIs for disks, GetIfTable2
 for interfaces, GetTickCount64 for uptime, and the registry for names.

 Compiled for Windows but not run: no Windows machine was available. Not done:
 temperatures (ACPI thermal zones via WMI) and full command lines.
*>
module bleu::sysinfo::win @feat(WIN32);
import std::collections::list, std::collections::maybe, std::time, bleu::availability, bleu::error, bleu::observe, bleu::rt::worker, bleu::sysinfo, bleu::sysinfo::delta;

struct WinBackend
{
	Allocator allocator;
	Duration interval;
	uint process_count;
	List{delta::CpuLine} previous_cpu;
	List{delta::NetCounters} previous_net; // names are owned by `allocator`
	List{delta::ProcessTicks} previous_processes;
}

const Driver DRIVER = {
	.info = { "win32", "Windows NT system APIs and the registry", 10 },
	.id = WIN32,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.set(CPU_FREQUENCY, { DEGRADED, "clock values are empty where the processor driver reports none" });
	capabilities.set(
		TEMPERATURES,
		availability::no(UNSUPPORTED_BACKEND, "ACPI thermal zones through WMI are not implemented")
	);
	capabilities.set(
		PROCESS_COMMAND,
		availability::no(
			UNSUPPORTED_BACKEND,
			"command lines need a remote read of the process environment block, not implemented"
		)
	);
	capabilities.set(
		PROCESS_USER,
		{ DEGRADED, "owners of processes in other sessions or of elevated processes are empty without elevation" }
	);
	WinBackend* backend = alloc::new(
		allocator,
		WinBackend,
		{
			.allocator = allocator,
			.interval = options.interval,
			.process_count = options.process_count,
		}
	);
	backend.previous_cpu.init(allocator);
	backend.previous_net.init(allocator);
	backend.previous_processes.init(allocator);
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	WinBackend* backend = (WinBackend*)state;
	foreach (counters : backend.previous_net)
	{
		alloc::free(allocator, counters.name.ptr);
	}
	backend.previous_net.free();
	backend.previous_cpu.free();
	backend.previous_processes.free();
	alloc::free(allocator, backend);
}

fn void run(void* state, SysinfoHub* hub, Host{Command}* host)
{
	WinBackend* backend      = (WinBackend*)state;
	sysinfo::Sampler sampler = { .reader = backend, .sample = &sample };
	sysinfo::run_sampler(&sampler, hub, host, backend.interval);
}

<*
 Read one sample. The load average is empty: Windows has no equivalent. Every
 temporary is in tmem; the state and the next counters are copied out after
 every read succeeded.
*>
fn void? sample(void* reader, Snapshot{State}* snapshot, Duration elapsed)
{
	WinBackend* backend = (WinBackend*)reader;
	Allocator allocator = snapshot.allocator();
	State* state        = &snapshot.value;
	@pool()
	{
		delta::CpuLine[] lines = processor_lines()!;
		uint processors        = sysinfo::count_processors(lines);
		sysinfo::fill_cpu(&state.cpu, allocator, lines, backend.previous_cpu.array_view());
		processor_frequencies(&state.cpu);
		state.cpu.model = cpu_model().copy(allocator);
		state.memory = memory_figures()!;
		state.mounts = read_mounts(allocator)!;
		delta::NetCounters[] counters = read_interfaces()!;
		state.interfaces = sysinfo::interface_rates(&backend.previous_net, allocator, counters, elapsed);
		sysinfo::ProcessSample[] all = read_processes(backend, elapsed, processors)!;
		state.processes = sysinfo::top_processes(backend.process_count, allocator, all);
		state.identity = read_identity(allocator)!;
		backend.previous_cpu.clear();
		backend.previous_cpu.push_all(lines);
		sysinfo::replace_counters(&backend.previous_net, backend.allocator, counters);
		backend.previous_processes.clear();
		foreach (&sampled : all)
		{
			backend.previous_processes.push(sampled.ticks);
		}
	};
	return;
}