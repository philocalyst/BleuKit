<*
 The shape every Bleu service takes when it is exposed by name.

 A service is described once, by a `Spec` (a constant table entry). The `Spec`
 holds the open, close, read and watch functions of that service, generated from
 the service's own types, plus its command table. `Slot` (service.c3) is one
 opened or failed service; `bleu_registry` never names a service's state type
 outside its `svc_<name>.c3` file.
*>
module bleu::registry;
import std::time, bleu::json;

<* What a service may be told when it is opened. Services ignore the fields they do not use. *>
struct OpenOptions
{
	// Prefix for kernel pseudo-files and device nodes, "" for the real system. Tests use a fake tree.
	String root;
}

<* Opens one service. Returns the service's handle (its `Battery*`, `Sysinfo*`, ...), or why it cannot run. *>
alias OpenFn = fn void*?(Allocator allocator, OpenOptions options);

<* Releases a handle returned by `OpenFn`. *>
alias CloseFn = fn void(void* handle);

<* Writes `{"generation": n, "state": ...}` for the latest state. *>
alias StateFn = fn void?(void* handle, json::JsonWriter* out);

<* Writes the array of `{"cap", "reason", "note"}` objects, one per capability. *>
alias CapabilitiesFn = fn void?(void* handle, json::JsonWriter* out);

<* The name of the backend in use. *>
alias BackendFn = fn String(void* handle);

<* Delivers each state, as JSON text, to `Tap.sink`, starting with the current one. *>
alias WatchFn = fn void?(void* handle, Tap* tap);

<* Receives the JSON text of one state. Runs on the service's worker thread; must not block. *>
alias Sink = fn void(void* context, String text);

<*
 Where a watch delivers. The tap is owned by the caller and must outlive the
 service: `Slot.close` stops the service before the tap can be released.
*>
struct Tap
{
	Sink sink;
	void* context;
}

<*
 One request on its way to a command. The command writes its result object
 into `out` (it starts with `"ok": true`) and returns a fault to report an error.
*>
struct Request
{
	// The opened service, of the type the command was written for.
	void* handle;
	// The request's params object. Its `object` is null when the request had none.
	json::read::Params params;
	// Where the result object goes.
	json::JsonWriter* out;
	// Longest a command waits for each operation it starts before cancelling it.
	Duration timeout;
}

<* Runs one command. *>
alias CommandFn = fn void?(Request* request);

<* One method a service exposes, named `<service>.<verb>`. *>
struct Command
{
	String name;
	String summary;
	// Default wait for the operation this command starts; 0 means `DEFAULT_TIMEOUT`.
	Duration timeout;
	CommandFn run;
}

<* How long a command waits for its operation when it does not name a longer wait. *>
const Duration DEFAULT_TIMEOUT = (Duration)10_000_000;

<*
 A service as the registry knows it. The table entries are `const`, one per service.
*>
struct Spec
{
	String name;
	String summary;
	OpenFn open;
	CloseFn close;
	StateFn state;
	CapabilitiesFn capabilities;
	BackendFn backend;
	WatchFn watch;
	Command[] commands;
}