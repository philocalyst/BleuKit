<*
 `bleuctl`: command-line client for `bleud`, or the same commands run in-process
 with `--embedded`. See options.c3 for the command line.
*>
module bleuctl;
import std::io, bleu::error, bleuctl::options, bleuctl::client, bleuctl::embedded;

fn int main(String[] args)
{
	options::Options? parsed = options::parse(args);
	if (catch err = parsed)
	{
		io::eprintfn("bleuctl: %s\n%s", error::last().message(), options::USAGE);
		return 2;
	}
	options::Options opts = parsed;
	if (opts.help)
	{
		io::printf("%s", options::USAGE);
		return 0;
	}
	int? code = opts.embedded ? embedded::run(opts) : client::run(opts);
	if (catch err = code)
	{
		io::eprintfn("bleuctl: %s", error::last().message());
		return 1;
	}
	return code;
}
