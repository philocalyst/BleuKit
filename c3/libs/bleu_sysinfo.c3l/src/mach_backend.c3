<*
 The Mach backend: macOS host_* statistics, sysctl, libproc, getifaddrs and
 getmntinfo, sampled every `Options.interval`.

 Compiled for macOS but not run: no Mac was available. The layouts and
 constants are cited in mach_native.c3. Temperatures (SMC, private) and full
 command lines (KERN_PROCARGS2) are not implemented; their capabilities say so.
*>
module bleu::sysinfo::mach @feat(DARWIN);
import std::collections::list, std::collections::maybe, std::time, bleu::availability, bleu::error, bleu::observe, bleu::rt::worker, bleu::sysinfo, bleu::sysinfo::delta;

struct MachBackend
{
	Allocator allocator;
	Duration interval;
	uint process_count;
	TimebaseInfo timebase;
	List{delta::CpuLine} previous_cpu;
	List{delta::NetCounters} previous_net; // names are owned by `allocator`
	List{delta::ProcessTicks} previous_processes;
}

const Driver DRIVER = {
	.info = { "mach", "macOS host_statistics, sysctl, libproc, getifaddrs", 10 },
	.id = MACH,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// Every macOS release has these interfaces, so the backend is always available here.
fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.set(CPU_FREQUENCY, availability::no(UNSUPPORTED_BACKEND, "macOS has no public per-core clock API"));
	capabilities.set(TEMPERATURES, availability::no(UNSUPPORTED_BACKEND, "sensors need the private SMC interface, not implemented"));
	capabilities.set(PROCESS_COMMAND, availability::no(UNSUPPORTED_BACKEND, "full command lines need KERN_PROCARGS2, not implemented"));
	TimebaseInfo timebase;
	if (mach_timebase_info(&timebase) != 0) return error::raise(error::BACKEND_FAILURE, error::Domain.MACH, 0, "mach_timebase_info failed")~;
	MachBackend* backend = alloc::new(allocator, MachBackend, {
		.allocator = allocator,
		.interval = options.interval,
		.process_count = options.process_count,
		.timebase = timebase,
	});
	backend.previous_cpu.init(allocator);
	backend.previous_net.init(allocator);
	backend.previous_processes.init(allocator);
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	MachBackend* backend = (MachBackend*)state;
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
	MachBackend* backend = (MachBackend*)state;
	sysinfo::Sampler sampler = { .reader = backend, .sample = &sample };
	sysinfo::run_sampler(&sampler, hub, host, backend.interval);
}

<*
 Read one sample. Every temporary is in tmem; the state and the next sample's
 counters are copied out only after every read succeeded.
*>
fn void? sample(void* reader, Snapshot{State}* snapshot, Duration elapsed)
{
	MachBackend* backend = (MachBackend*)reader;
	Allocator allocator = snapshot.allocator();
	State* state = &snapshot.value;
	@pool()
	{
		delta::CpuLine[] lines = processor_lines()!;
		uint processors = sysinfo::count_processors(lines);
		sysinfo::fill_cpu(&state.cpu, allocator, lines, backend.previous_cpu.array_view());
		state.cpu.model = (sysctl_text("machdep.cpu.brand_string") ?? "").copy(allocator);
		LoadAverage[3] averages = load_averages()!;
		foreach (i, &average : averages)
		{
			state.cpu.load_average[i] = maybe::value(average);
		}
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
