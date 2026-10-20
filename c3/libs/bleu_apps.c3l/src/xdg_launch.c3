<*
 Launching on Linux: `Exec` expansion, the child's environment, terminals, and
 reaping. Same module as `xdg_desktop.c3`, which owns the backend state.
*>
module bleu::apps::xdg_desktop @feat(LINUX);
import std::os::process, std::os::posix, std::collections::list, bleu::apps, bleu::error, bleu::xdg::exec;

const String ENV_STARTUP_ID = "DESKTOP_STARTUP_ID";
const String ENV_ACTIVATION_TOKEN = "XDG_ACTIVATION_TOKEN";

<*
 Start `app` (or its `action`) for `request`. Each invocation that Exec expands to
 is started; the result carries the first child's pid.

 @return? error::PROTOCOL : "The Exec line is malformed or has a field code that does not fit"
 @return? error::UNAVAILABLE : "A terminal was needed and none of the configured ones started"
 @return? error::BACKEND_FAILURE : "The program could not be started"
*>
fn Launched? launch(void* state, App* app, AppAction* action, LaunchRequest* request)
{
	XdgXdgBackend* backend = (XdgBackend*)state;
	String exec = action != null ? action.exec : app.target;
	Context context = {
		.files = request.files,
		.urls = request.uris,
		.icon = app.icon,
		.name = app.name,
		.location = app.location,
	};
	String[][] invocations = exec::expand(tmem, exec, context)!;
	String[] environment = child_environment(request, tmem);
	Launched result = { .route = app.terminal ? LaunchRoute.TERMINAL : LaunchRoute.SPAWN, .pid = 0 };
	foreach (i, invocation : invocations)
	{
		String[] argv = append_strings(invocation, request.args);
		long pid = app.terminal ? spawn_in_terminal(backend, argv, environment)! : spawn_argv(backend, argv, environment)!;
		if (i == 0) result.pid = pid;
	}
	return result;
}

<*
 The environment a child is started with: this process's variables, minus any
 activation token or startup id left over from an earlier launch, plus the ones
 this request carries.
*>
fn String[] child_environment(LaunchRequest* request, Allocator allocator) @local
{
	List{String} vars;
	vars.init(allocator);
	defer vars.free();
	ZString* entries = posix::environ;
	for (usz i = 0; entries[i] != null; i++)
	{
		String entry = entries[i].str_view();
		if (entry.starts_with(ENV_STARTUP_ID) || entry.starts_with(ENV_ACTIVATION_TOKEN)) continue;
		vars.push(entry.copy(allocator));
	}
	if (request.startup_id.len > 0) vars.push(string::tformat("%s=%s", ENV_STARTUP_ID, request.startup_id).copy(allocator));
	if (request.activation_token.len > 0) vars.push(string::tformat("%s=%s", ENV_ACTIVATION_TOKEN, request.activation_token).copy(allocator));
	return vars.to_aligned_array(allocator);
}

// `invocation` followed by `extra`, in a new array from `tmem`.
fn String[] append_strings(String[] invocation, String[] extra) @local
{
	List{String} argv;
	argv.tinit();
	argv.push_all(invocation);
	argv.push_all(extra);
	return argv.to_tarray();
}

<*
 Start `argv` as a child process with the standard streams inherited.

 @return? error::BACKEND_FAILURE : "The program could not be started"
*>
fn long? spawn_argv(XdgXdgBackend* backend, String[] argv, String[] environment) @local
{
	Process? started = process::spawn(argv, (process::SpawnOptions)0, environment, process::INHERIT, process::INHERIT, process::INHERIT);
	if (catch err = started)
	{
		return error::raise(error::BACKEND_FAILURE, error::Domain.ERRNO, 0, "cannot start %s", argv[0])~;
	}
	Process process = started;
	long pid = (long)process.child;
	(void)process.destroy();
	backend.children.push((int)pid);
	return pid;
}

<*
 Start `argv` inside the first terminal of the configured list that starts.
 Each terminal is given the command after `-e`.
*>
fn long? spawn_in_terminal(XdgXdgBackend* backend, String[] argv, String[] environment) @local
{
	foreach (terminal : backend.terminals)
	{
		List{String} wrapped;
		wrapped.tinit();
		wrapped.push(terminal);
		wrapped.push(TERMINAL_OPTION);
		wrapped.push_all(argv);
		if (try pid = spawn_argv(backend, wrapped.to_tarray(), environment)) return pid;
	}
	return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "no terminal emulator could be started")~;
}

<*
 Collect the children that have exited, so that they do not stay zombies. A
 child still running is kept for the next pass.
*>
fn void reap(XdgXdgBackend* backend)
{
	int[] pids = backend.children.to_tarray();
	backend.children.clear();
	foreach (pid : pids)
	{
		int status;
		if (posix::waitpid((Pid_t)pid, &status, posix::WNOHANG) == 0) backend.children.push(pid);
	}
}
