<*
 Command-line options of `bleuctl`.

   bleuctl [--socket PATH] list
   bleuctl [--socket PATH] state <service>
   bleuctl [--socket PATH] caps <service>
   bleuctl [--socket PATH] watch <service>
   bleuctl [--socket PATH] call <method> [json-params]
   bleuctl --embedded [--fake-root DIR] <command> ...

 `--embedded` runs the same commands in this process, opening the service itself
 instead of asking a running `bleud`.
*>
module bleuctl::options;
import bleu::error;

<* What `bleuctl` was asked to do. *>
struct Options
{
	bool embedded; // open services in this process, without a daemon
	bool help; // print the usage and exit
	String socket; // socket path; "" for the default
	String fake_root; // embedded only: prefix for kernel pseudo-files; "" for the real system
	String command; // list, state, caps, watch or call
	String target; // the service, or the method for `call`
	String params; // `call`'s params as JSON; "{}" when left out
}

<* The usage text. *>
const String USAGE = "usage: bleuctl [--socket PATH | --embedded [--fake-root DIR]] (list | state <svc> | caps <svc> | watch <svc> | call <method> [json])\n";

<*
 Read the command line. `args[0]` is the program name and is skipped.

 @return? error::INVALID_ARGUMENT : "An option or command is unknown or incomplete; the message names it"
*>
fn Options? parse(String[] args)
{
	Options options = { .params = "{}" };
	usz i = 1;
	while (i < args.len && args[i].len > 0 && args[i][0] == '-')
	{
		String flag = args[i];
		i++;
		if (flag == "--embedded")
		{
			options.embedded = true;
		}
		else if (flag == "--help" || flag == "-h")
		{
			options.help = true;
		}
		else if (flag == "--socket" || flag == "--fake-root")
		{
			if (i >= args.len)
			{
				return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "%s needs a value", flag)~;
			}
			if (flag == "--socket")
			{
				options.socket = args[i];
			}
			else
			{
				options.fake_root = args[i];
			}
			i++;
		}
		else
		{
			return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "unknown option: %s", flag)~;
		}
	}
	if (options.help) return options;
	if (i >= args.len)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "no command given")~;
	}
	options.command = args[i];
	i++;
	bool needs_target = options.command == "state" || options.command == "caps"
		|| options.command == "watch" || options.command == "call";
	if (!needs_target && options.command != "list")
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "unknown command: %s", options.command)~;
	}
	if (needs_target)
	{
		if (i >= args.len)
		{
			return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "%s needs an argument", options.command)~;
		}
		options.target = args[i];
		i++;
	}
	if (options.command == "call" && i < args.len)
	{
		options.params = args[i];
		i++;
	}
	if (i < args.len)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "unexpected argument: %s", args[i])~;
	}
	return options;
}
