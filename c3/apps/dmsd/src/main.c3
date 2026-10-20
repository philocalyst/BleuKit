<*
 dmsd: DankMaterialShell's Go `core` server, rebuilt on Bleu.

 The unmodified DMS shell connects to the socket this process serves
 (`$XDG_RUNTIME_DIR/dmsd-<pid>.sock`, or `--socket PATH`) and speaks DMS's
 line-JSON protocol. Each DMS module is one file (`mod_<name>.c3`) listed in
 `main`; see docs/DMSD.md for the coverage and the adding-a-module recipe.

 Usage: dmsd [--socket PATH] [--fake-root DIR] [--module-off NAME]... [--debug]

   --socket PATH      serve on PATH instead of the DMS default
   --fake-root DIR    read brightness from the sysfs tree under DIR and do not use logind (tests)
   --module-off NAME  do not start module NAME (repeatable): brightness, loginctl
   --debug            print what the modules do to stderr

 SIGINT and SIGTERM stop the daemon: the IPC server stops first, then the modules
 are stopped in reverse order of their start, and everything is freed.
*>
module dmsd;
import std::io, std::collections::list, std::os::posix, libc, bleu::ipc, bleu::error, dmsd::contract, dmsd::capabilities, dmsd::core_methods, dmsd::loginctl_mod, dmsd::brightness_mod;

// DMS's protocol version (server.go:42), as the handshake and getServerInfo report it.
const int DMS_API_VERSION = 38;

// The pipe a signal handler writes to; `serve` blocks reading its other end.
CInt shutdown_fd = -1;

// Async-signal-safe: one write(2), no allocation, no locks.
fn void on_signal(CInt signal, void* info, void* ucontext) @private
{
	char byte = 1;
	libc::write(shutdown_fd, &byte, 1);
}

// POSIX pipe(2). The C library's binding is not in std::os::posix, so it is declared here.
extern fn CInt pipe(CInt* fds);

fn void usage() @private
{
	io::eprintfn("usage: dmsd [--socket PATH] [--fake-root DIR] [--module-off NAME]... [--debug]");
}

// Read the command line into `options`. Unknown arguments are errors, not ignored.
fn void? parse_args(String[] args, contract::Options* options) @private
{
	for (sz i = 1; i < args.len; i++)
	{
		String arg = args[i];
		if (arg == "--debug")
		{
			contract::debug_logging = true;
			continue;
		}
		if (arg == "--socket" || arg == "--fake-root" || arg == "--module-off")
		{
			if (i + 1 >= args.len)
			{
				return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "%s needs a value", arg)~;
			}
			i++;
			String value = args[i];
			if (arg == "--socket")
			{
				options.socket_path = value;
			}
			else if (arg == "--fake-root")
			{
				options.fake_root = value;
			}
			else
			{
				options.module_off.push(value);
			}
			continue;
		}
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "unknown argument '%s'", arg)~;
	}
}

// Block until a signal handler writes the shutdown byte (or the pipe fails).
fn void wait_for_signal(CInt fd) @private
{
	char[1] buffer;
	libc::read(fd, &buffer, 1);
}

// Start the server and the modules, serve until a signal, then stop everything. Returns the exit status.
fn int serve(contract::Context* context, contract::Module[] modules, CInt wait_fd) @private
{
	ipc::Server* server = context.server;
	int status = 0;
	if (catch server.start())
	{
		contract::warn("cannot start the IPC server: %s", error::last().message());
		status = 1;
	}
	else
	{
		contract::note("serving on %s", server.socket_path);
		wait_for_signal(wait_fd);
		contract::note("shutting down");
	}
	server.stop();
	for (sz i = modules.len - 1; i >= 0; i--)
	{
		if (!modules[i].running) continue;
		modules[i].stop(context, &modules[i]);
		modules[i].running = false;
	}
	server.free();
	return status;
}

fn int main(String[] args)
{
	contract::Options options = { };
	options.module_off.init(mem);
	defer options.module_off.free();
	if (catch parse_args(args, &options))
	{
		contract::warn("%s", error::last().message());
		usage();
		return 2;
	}
	CInt[2] fds;
	if (pipe(&fds) != 0)
	{
		contract::warn("cannot create the shutdown pipe");
		return 1;
	}
	shutdown_fd = fds[1];
	posix::install_signal_handler(libc::SIGINT, &on_signal);
	posix::install_signal_handler(libc::SIGTERM, &on_signal);

	ipc::Server server;
	contract::Context context = { .allocator = mem, .options = &options, .server = &server };
	ipc::Config config = {
		.app_name = "dmsd",
		.api_version = DMS_API_VERSION,
		.socket_path = options.socket_path,
		.capabilities_fn = &capabilities::handshake,
		.capabilities_context = &context,
	};
	if (catch server.init(mem, config))
	{
		contract::warn("cannot prepare the IPC server: %s", error::last().message());
		return 1;
	}
	server.register_method("getServerInfo", &core_methods::get_server_info, &context)!!;
	server.register_method("shell.ready", &core_methods::handle_shell_ready, &context)!!;

	// Order is DMS's capability order (server.go getCapabilities): loginctl, then brightness.
	contract::Module[2] modules = { loginctl_mod::descriptor(), brightness_mod::descriptor() };
	for (sz i = 0; i < modules.len; i++)
	{
		contract::Module* mod = &modules[i];
		if (options.disables(mod.name))
		{
			contract::note("%s: off by --module-off", mod.name);
			continue;
		}
		mod.running = mod.start(&context, mod);
	}
	List{String} names;
	names.init(mem);
	defer names.free();
	capabilities::collect(modules[..], &names);
	context.capabilities = names.array_view();

	int status = serve(&context, modules[..], fds[0]);
	libc::close(fds[0]);
	libc::close(fds[1]);
	return status;
}
