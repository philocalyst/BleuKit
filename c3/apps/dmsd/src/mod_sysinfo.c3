<*
 The `dgop` module: DMS's system-information methods over `bleu::sysinfo`.

 Methods: `dgop.meta` (for the modules `cpu`, `memory`, `processes` and `system`, which
 Bleu reports), `dgop.modules` (the modules this daemon computes), and refused:
 `dgop.gpu` and `dgop.hardware` (Bleu's sysinfo reads no GPU or hardware inventory).
 Capability `dgop`: DMS always advertises it (server.go getCapabilities, `dgop` in the
 first list), and this module provides the methods the shell reads for CPU, memory and
 processes.

 Sources: dgop's `gops/meta.go` (module list, `GetMeta`) and `models/meta.go`,
 `models/cpu.go`, `models/memory.go`, `models/process.go` at dgop master, and
 DMS's `core/internal/server/dgop/handlers.go` (the parameters and their defaults).
 Every field Bleu does not report is written as zero or empty, and docs/DMSD.md lists them.
*>
module dmsd::sysinfo_mod;
import std::collections::maybe, std::collections::object, std::time, bleu::observe, bleu::sysinfo, bleu::error, bleu::ipc, bleu::json, dmsd::contract, dmsd::wire, dmsd::params, dmsd::param_lists, dmsd::replies;

const String[1] CAPABILITIES = { "dgop" };

// dgop's module names (gops/meta.go, `availableModules`), in dgop's order.
const String[12] DGOP_MODULES    = {
	"cpu",
	"memory",
	"network",
	"net-rate",
	"disk",
	"disk-rate",
	"diskmounts",
	"processes",
	"system",
	"hardware",
	"gpu",
	"gpu-temp",
};
// The modules this daemon computes, in dgop's order: the subset of DGOP_MODULES Bleu reports.
const String[4] SERVED_MODULES   = { "cpu", "memory", "processes", "system" };
// dgop's default process limit (dgop/handlers.go: `limit`, 20).
const long DEFAULT_PROCESS_LIMIT = 20;
// Processes the service keeps per sample. A larger `limit` is clamped to this.
const uint PROCESS_COUNT         = 500;
const long MAX_PROCESS_LIMIT     = 500;
// The sort order dmsd can give: the service sorts by CPU, which is dgop's default.
const String SORT_BY_CPU         = "cpu";
// Bytes per kibibyte (dgop's `memoryKB` and `rssKB`).
const ulong BYTES_PER_KIB        = 1024;
// How long a `dgop` request waits for the first sample of a fresh service.
const Duration SAMPLE_WAIT       = (Duration)2_000_000;
// Reply text for the modules Bleu cannot serve.
const String GPU_REASON          = "not supported: Bleu's sysinfo reads no GPU; the gpu module is not served";
const String HARDWARE_REASON     = "not supported: Bleu's sysinfo reads no hardware inventory (DMI, PCI); the hardware module is not served";

// The refused methods.
const replies::Refusal[2] REFUSALS = {
	{ .method = "dgop.gpu", .text = GPU_REASON },
	{ .method = "dgop.hardware", .text = HARDWARE_REASON },
};

// Which of the served modules a request names. A module Bleu cannot serve is named but never set.
struct Selection
{
	bool cpu;
	bool memory;
	bool processes;
	bool system;
}

<* The module's runtime state. Allocated in `start`, freed in `stop`. *>
struct SysinfoModule
{
	sysinfo::Sysinfo* service;
}

// Whether `name` is one of dgop's modules (served or not).
fn bool is_dgop_module(String name) @private
{
	foreach (known : DGOP_MODULES)
	{
		if (known == name) return true;
	}
	return false;
}

<*
 The modules a `dgop.meta` request names (dgop's `GetMeta`): `all` selects every served
 module, a module outside dgop's list is "unknown module: <name>", and a module Bleu
 cannot serve is ignored, as DMS ignores a module whose read fails.
*>
fn Selection? select_modules(String[] names) @private
{
	Selection selected;
	foreach (name : names)
	{
		if (name == "all")
		{
			return (Selection) { .cpu = true, .memory = true, .processes = true, .system = true };
		}
		if (name == "cpu")
		{
			selected.cpu = true;
		}
		else if (name == "memory")
		{
			selected.memory = true;
		}
		else if (name == "processes")
		{
			selected.processes = true;
		}
		else if (name == "system")
		{
			selected.system = true;
		}
		else if (!is_dgop_module(name))
		{
			return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "unknown module: %s", name)~;
		}
	}
	return selected;
}

// A float32 field, written as Go writes a float32 (`put_float` takes the 32-bit value).
fn void? float_field(json::JsonWriter* w, String key, float value) @private
{
	w.key(key)!;
	w.put_float(value)!;
}

// The machine's usage in dgop's own unit: a whole-machine percentage, 0 when Bleu has none yet.
fn double usage_or_zero(Maybe{sysinfo::Percent} value) @private
{
	return value.has_value ? (double)(float)value.value : 0.0;
}

// dgop's `CPUInfo` (models/cpu.go), in the Go field order.
fn void? write_cpu(json::JsonWriter* w, sysinfo::Cpu* cpu) @private
{
	w.begin_object()!;
	wire::key_int(w, "count", (long)cpu.cores.len)!;
	wire::key_string(w, "model", cpu.model)!;
	// Bleu reports no clock for the whole machine and no temperature for the CPU alone.
	wire::key_double(w, "frequency", 0.0)!;
	wire::key_double(w, "temperature", 0.0)!;
	wire::key_double(w, "usage", usage_or_zero(cpu.usage))!;
	w.key("coreUsage")!;
	w.begin_array()!;
	foreach (&core : cpu.cores) w.put_double(usage_or_zero(core.usage))!;
	w.end_array()!;
	// dgop's cumulative tick counters (`total`, `cores`) are the cursor's input; Bleu computes its own rates.
	w.key("total")!;
	w.begin_array()!;
	w.end_array()!;
	w.key("cores")!;
	w.begin_array()!;
	w.end_array()!;
	w.end_object()!;
}

// dgop's `MemoryInfo` (models/memory.go), in the Go field order.
fn void? write_memory(json::JsonWriter* w, sysinfo::Memory* memory) @private
{
	double used_percent = memory.total > 0 ? (double)memory.used * 100.0 / (double)memory.total : 0.0;
	ulong swap_free     = memory.swap_total > memory.swap_used ? memory.swap_total - memory.swap_used : 0UL;
	w.begin_object()!;
	wire::key_uint(w, "total", memory.total)!;
	wire::key_uint(w, "used", memory.used)!;
	wire::key_double(w, "usedPercent", used_percent)!;
	// Bleu reports what applications can take (`available`), not the free count dgop reports.
	wire::key_uint(w, "free", 0)!;
	wire::key_uint(w, "available", memory.available)!;
	wire::key_uint(w, "buffers", 0)!;
	wire::key_uint(w, "cached", memory.cache.has_value ? memory.cache.value : 0)!;
	wire::key_uint(w, "sreclaimable", 0)!;
	wire::key_uint(w, "shared", 0)!;
	wire::key_uint(w, "zfsArcSize", 0)!;
	wire::key_uint(w, "gpuActive", 0)!;
	wire::key_uint(w, "gpuReclaim", 0)!;
	wire::key_uint(w, "swaptotal", memory.swap_total)!;
	wire::key_uint(w, "swapfree", swap_free)!;
	w.end_object()!;
}

// dgop's `ProcessInfo` (models/process.go), in the Go field order. `cpu_share` is the process's
// share of the whole machine (its CPU use divided by the processor count, as dgop reports it).
fn void? write_process(json::JsonWriter* w, sysinfo::Process* process, double cpu_share, ulong memory_total) @private
{
	ulong rss       = process.memory.has_value ? process.memory.value : 0UL;
	float rss_share = memory_total > 0 ? (float)((double)rss * 100.0 / (double)memory_total) : 0.0f;
	w.begin_object()!;
	wire::key_int(w, "pid", (long)process.pid)!;
	// Bleu does not read the parent pid.
	wire::key_int(w, "ppid", 0)!;
	wire::key_double(w, "cpu", cpu_share)!;
	// Cumulative CPU seconds: not read.
	wire::key_double(w, "pticks", 0.0)!;
	float_field(w, "memoryPercent", rss_share)!;
	// Bleu reports the resident set size only, so the memory columns are that value.
	wire::key_uint(w, "memoryKB", rss / BYTES_PER_KIB)!;
	wire::key_string(w, "memoryCalculation", "")!;
	wire::key_uint(w, "rssKB", rss / BYTES_PER_KIB)!;
	float_field(w, "rssPercent", rss_share)!;
	// Proportional set size: not read.
	wire::key_uint(w, "pssKB", 0)!;
	float_field(w, "pssPercent", 0.0)!;
	wire::key_string(w, "username", process.user)!;
	wire::key_string(w, "command", process.name)!;
	wire::key_string(w, "fullCommand", process.command)!;
	w.end_object()!;
}

// The processes of one snapshot, busiest first, at most `limit` of them (dgop's `processes`).
fn void? write_processes(json::JsonWriter* w, sysinfo::State* state, long limit, bool with_cpu) @private
{
	usz shown           = (usz)(limit < (long)state.processes.len ? limit : (long)state.processes.len);
	double machine_cpus = state.cpu.cores.len > 0 ? (double)state.cpu.cores.len : 1.0;
	w.key("processes")!;
	w.begin_array()!;
	for (usz i = 0; i < shown; i++)
	{
		sysinfo::Process* process = &state.processes[i];
		double share              = with_cpu && process.cpu.has_value ? (double)(float)process.cpu.value / machine_cpus
			: 0.0;
		write_process(w, process, share, state.memory.total)!;
	}
	w.end_array()!;
}

// dgop's `SystemInfo` (models/meta.go). The load average is written with two decimals, as /proc/loadavg prints it.
fn void? write_system(json::JsonWriter* w, sysinfo::State* state) @private
{
	String loadavg = "";
	if (state.cpu.load_average[0].has_value && state.cpu.load_average[1].has_value
		&& state.cpu.load_average[2].has_value)
	{
		loadavg = string::tformat(
			"%.2f %.2f %.2f",
			(double)(float)state.cpu.load_average[0].value,
			(double)(float)state.cpu.load_average[1].value,
			(double)(float)state.cpu.load_average[2].value
		);
	}
	w.begin_object()!;
	wire::key_string(w, "loadavg", loadavg)!;
	// Bleu's sample does not count the machine's processes or threads (it keeps only the busiest).
	wire::key_int(w, "processes", 0)!;
	wire::key_int(w, "threads", 0)!;
	// The boot time string dgop writes is not reproduced: left empty.
	wire::key_string(w, "boottime", "")!;
	w.end_object()!;
}

// `dgop.meta` (dgop's MetaInfo, models/meta.go): the selected modules in the Go field order.
fn String? render_meta(
	Allocator allocator,
	sysinfo::State* state,
	Selection selected,
	long limit,
	bool with_cpu,
	bool sort_by_cpu
) @private
{
	wire::Line line;
	line.begin(allocator);
	json::JsonWriter* w = &line.writer;
	w.begin_object()!;
	if (selected.cpu)
	{
		w.key("cpu")!;
		write_cpu(w, &state.cpu)!;
	}
	if (selected.memory)
	{
		w.key("memory")!;
		write_memory(w, &state.memory)!;
	}
	// dgop omits an empty list (omitempty); so does this. A sort other than CPU is not served.
	long shown = limit < MAX_PROCESS_LIMIT ? limit : MAX_PROCESS_LIMIT;
	if (selected.processes && sort_by_cpu && shown > 0 && state.processes.len > 0)
	{
		write_processes(w, state, shown, with_cpu)!;
	}
	if (selected.system)
	{
		w.key("system")!;
		write_system(w, state)!;
	}
	w.end_object()!;
	return line.finish();
}

// `dgop.modules`: the modules this daemon computes, in dgop's order (`ModulesInfo`, models/meta.go).
fn String? render_modules(Allocator allocator) @private
{
	wire::Line line;
	line.begin(allocator);
	line.writer.begin_object()!;
	line.writer.key("available")!;
	line.writer.begin_array()!;
	foreach (name : SERVED_MODULES) line.writer.put_string(name)!;
	line.writer.end_array()!;
	line.writer.end_object()!;
	return line.finish();
}

// The newest sample. A fresh service has none for its first sampling period, so this waits for one.
fn observe::Snapshot{sysinfo::State}*? latest_sample(SysinfoModule* m) @private
{
	return m.service.wait_after(0, SAMPLE_WAIT);
}

fn void? meta(SysinfoModule* m, ipc::Call* call) @private
{
	String[] names = param_lists::strings(call.params, "modules", tmem);
	if (names.len == 0) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "modules is required")~;
	Selection selected = select_modules(names)!;
	long limit         = params::opt_int(call.params, "limit", DEFAULT_PROCESS_LIMIT);
	bool with_cpu      = !params::opt_bool(call.params, "noCpu", false);
	bool sort_by_cpu   = true;
	if (try sort = json::read::get_string(call.params, "sort")) sort_by_cpu = sort == SORT_BY_CPU;
	observe::Snapshot{sysinfo::State}* sample = latest_sample(m)!;
	defer sample.release();
	call.respond_raw(render_meta(tmem, &sample.value, selected, limit, with_cpu, sort_by_cpu)!);
}

fn void handle_meta(void* context, ipc::Call* call)
{
	SysinfoModule* m = (SysinfoModule*)context;
	@pool()
	{
		if (catch meta(m, call)) call.respond_error(contract::failure_text("failed to read the system metrics"));
	};
}

fn void? modules(ipc::Call* call) @private
{
	call.respond_raw(render_modules(tmem)!);
}

fn void handle_modules(void* context, ipc::Call* call)
{
	@pool()
	{
		if (catch modules(call)) call.respond_error(contract::failure_text("failed to list the modules"));
	};
}

fn void handle_refused(void* context, ipc::Call* call)
{
	replies::answer(REFUSALS[..], call);
}

<* Start the dgop module, or report why not and return false. *>
fn bool start(contract::Context* context, contract::Module* self)
{
	sysinfo::Options options = { .process_count = PROCESS_COUNT };
	sysinfo::Sysinfo* service;
	if (try opened = sysinfo::open(context.allocator, options))
	{
		service = opened;
	}
	else
	{
		contract::warn("dgop: not started: no system information service could be opened");
		return false;
	}
	SysinfoModule* m = alloc::new(context.allocator, SysinfoModule);
	m.service = service;
	context.server.register_method("dgop.meta", &handle_meta, m)!!;
	context.server.register_method("dgop.modules", &handle_modules, m)!!;
	replies::register_all(context.server, REFUSALS[..], &handle_refused)!!;
	self.state = m;
	return true;
}

<* Stop the module: the sampler is closed. The server has stopped already. *>
fn void stop(contract::Context* context, contract::Module* self)
{
	SysinfoModule* m = (SysinfoModule*)self.state;
	m.service.close();
	alloc::free(context.allocator, m);
}

<* The module's descriptor for `main`. A global constant, so its slices point at static data. *>
const contract::Module DESCRIPTOR = {
	.name = "dgop",
	.start = &start,
	.stop = &stop,
	.capabilities = CAPABILITIES[..]
};

fn contract::Module descriptor() => DESCRIPTOR;