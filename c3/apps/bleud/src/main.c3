<*
 `bleud`: Bleu's daemon. Serves every Bleu service over the line-JSON IPC
 protocol of `bleu_ipc`, with the methods and topics described in README.md.
*>
module bleud;
import std::io, bleu::error, bleu::registry, bleud::options, bleud::daemon;

<* Print each service and whether it opened, with its backend or the reason it did not. *>
fn void print_list(registry::Slot[] slots)
{
	foreach (&slot : slots)
	{
		if (slot.handle)
		{
			io::printfn("%-12s %s", slot.spec.name, slot.spec.backend(slot.handle));
		}
		else if (slot.attempted)
		{
			io::printfn("%-12s unavailable: %s", slot.spec.name, slot.failure_message);
		}
		else
		{
			io::printfn("%-12s not selected", slot.spec.name);
		}
	}
}

fn int main(String[] args)
{
	options::Options? parsed = options::parse(args);
	if (catch err = parsed)
	{
		io::eprintf("bleud: %s\n%s", error::last().message(), options::USAGE);
		return 2;
	}
	options::Options opts = parsed;
	if (opts.help)
	{
		io::printf("%s", options::USAGE);
		return 0;
	}
	registry::OpenOptions open_options = { .root = opts.fake_root };
	registry::Slot[registry::SERVICE_COUNT] slots;
	if (catch err = registry::open_selected(slots[..], opts.services, mem, open_options))
	{
		io::eprintfn("bleud: %s", error::last().message());
		return 2;
	}
	if (opts.list)
	{
		print_list(slots[..]);
		return 0;
	}
	int? code = daemon::serve(slots[..], opts.socket);
	if (catch err = code)
	{
		io::eprintfn("bleud: %s", error::last().message());
		return 2;
	}
	return code;
}