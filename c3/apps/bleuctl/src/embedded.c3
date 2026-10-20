<*
 `bleuctl --embedded`: the same commands, run in this process. The service is
 opened here, so no daemon is needed; this is what scripts use on any platform.
*>
module bleuctl::embedded;
import std::io, std::thread, std::time, std::core::string, std::encoding::json, std::collections::object, bleu::error, bleu::json, bleu::registry, bleuctl::options, bleuctl::pretty;

<*
 Run `opts.command` in this process. A service that does not open is reported on
 stderr with the reason it gave, and the exit code is 1.

 @return "The exit code: 0 on success, 1 when the service did not open or the command failed"
 @return? NOT_FOUND : "No service has that name"
*>
fn int? run(options::Options opts)
{
	registry::OpenOptions open_options = { .root = opts.fake_root };
	if (opts.command == "list")
	{
		registry::Slot[registry::SERVICE_COUNT] slots;
		registry::open_selected(slots[..], "", mem, open_options)!!;
		list(slots[..]);
		return 0;
	}
	// A `call` names its method, `<service>.<verb>`; every other command names the service.
	String service = opts.target;
	if (opts.command == "call")
	{
		usz dot = 0;
		while (dot < service.len && service[dot] != '.') dot++;
		service = service[0:dot];
	}
	usz index = registry::index_of_service(service)!;
	registry::Slot slot;
	if (catch err = slot.open(registry::SERVICES[index], mem, open_options))
	{
		io::eprintfn("bleuctl: %s did not open: %s", service, slot.failure_message);
		return 1;
	}
	defer slot.close();
	if (opts.command == "watch")
	{
		slot.watch(&print_state, null)!;
		while (true) thread::sleep(time::ms(500))!!;
	}
	return one_shot(&slot, opts);
}

<* Print each service's summary as one object per line in a list. *>
fn void list(registry::Slot[] slots) @private
{
	foreach (&slot : slots)
	{
		@pool()
		{
			DString text;
			text.init(tmem);
			bleu::json::JsonWriter out;
			out.init_dstring(&text);
			slot.write_summary(&out)!!;
			print_pretty(out.written());
		};
	}
}

<* Run a command that answers once, and print its result. *>
fn int? one_shot(registry::Slot* slot, options::Options opts) @private
{
	@pool()
	{
		DString text;
		text.init(tmem);
		bleu::json::JsonWriter out;
		out.init_dstring(&text);
		if (opts.command == "state")
		{
			slot.write_state(&out)!;
		}
		else if (opts.command == "caps")
		{
			slot.write_capabilities(&out)!;
		}
		else
		{
			Object* params                 = parse_params(opts.params)!;
			bleu::json::read::Params given = { .object = params };
			slot.call(opts.target, given, &out)!;
		}
		print_pretty(out.written());
	};
	return 0;
}

<* The params object of a `call`, parsed in temporary memory. *>
fn Object*? parse_params(String text) @private
{
	return std::encoding::json::tparse(text);
}

<* Print a JSON value pretty, on stdout. *>
fn void print_pretty(String compact) @private
{
	@pool()
	{
		DString out;
		out.init(tmem);
		pretty::format(compact, &out);
		io::printn(out.str_view());
	};
}

<* Watch sink: print each state as it arrives. Runs on the service's worker thread. *>
fn void print_state(void* context, String text)
{
	print_pretty(text);
}