<*
 Command-line options of `bleud`.

   bleud [--services a,b,c] [--fake-root DIR] [--socket PATH]
   bleud --list [--services a,b,c] [--fake-root DIR]

 `--services` names the services to open (default: every service). `--fake-root`
 points the sysfs, procfs and DDC services at a fake tree for tests. `--socket`
 replaces `$XDG_RUNTIME_DIR/bleud.sock`.
*>
module bleud::options;
import bleu::error;

<* What `bleud` was asked to do. *>
struct Options
{
	bool list; // print the services and exit
	bool help; // print the usage and exit
	String services; // comma-separated; "" for every service
	String fake_root; // prefix for the kernel pseudo-files; "" for the real system
	String socket; // socket path; "" for the default
}

<*
 Read the command line. `args[0]` is the program name and is skipped.

 @return? error::INVALID_ARGUMENT : "An option is unknown or is missing its value; the message names it"
*>
fn Options? parse(String[] args)
{
	Options options;
	usz i = 1;
	while (i < args.len)
	{
		String arg = args[i];
		i++;
		if (arg == "--list")
		{
			options.list = true;
		}
		else if (arg == "--help" || arg == "-h")
		{
			options.help = true;
		}
		else if (arg == "--services" || arg == "--fake-root" || arg == "--socket")
		{
			if (i >= args.len)
			{
				return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "%s needs a value", arg)~;
			}
			String value = args[i];
			i++;
			if (arg == "--services") options.services = value;
			else if (arg == "--fake-root") options.fake_root = value;
			else options.socket = value;
		}
		else
		{
			return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "unknown option: %s", arg)~;
		}
	}
	return options;
}

<* The usage text, printed for `--help` and after a bad command line. *>
const String USAGE = "usage: bleud [--list] [--services a,b,c] [--fake-root DIR] [--socket PATH]\n";
