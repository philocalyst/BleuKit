<*
 `bleuctl` against a running `bleud`: one request per command, or a subscription
 for `watch`. Results are printed pretty; a failure is printed on stderr with the
 daemon's `<STATUS>: <message>` text and exit code 1.
*>
module bleuctl::client @feat(POSIX);
import std::io, std::time, std::core::string, std::encoding::json, std::collections::object, bleu::error, bleu::ipc, bleu::json, bleu::registry, bleuctl::options, bleuctl::pretty;

<* How long a request may wait for its reply. *>
const Duration REQUEST_TIMEOUT = (Duration)15_000_000;

<*
 Run the command over the socket at `opts.socket` (or the default).

 @return "The exit code: 0 on success, 1 when the daemon refused the request"
 @return? error::UNAVAILABLE : "No socket path or no daemon at it; the message says which"
*>
fn int? run(options::Options opts)
{
	String path = opts.socket;
	if (path.len == 0)
	{
		path = registry::default_socket_path(mem)!;
	}
	ipc::client::Client client;
	if (catch err = client.connect(mem, path, REQUEST_TIMEOUT))
	{
		io::eprintfn("bleuctl: cannot reach bleud at %s: %s", path, error::last().message());
		return 1;
	}
	defer client.free();
	if (opts.command == "watch")
	{
		return watch(&client, opts.target);
	}
	return request_once(&client, opts);
}

<* Send the one request of a one-shot command and print its reply. *>
fn int? request_once(ipc::client::Client* client, options::Options opts) @private
{
	@pool()
	{
		String method = request_method(opts);
		String line   = client.request(method, request_params(opts), REQUEST_TIMEOUT)!;
		defer alloc::free(mem, line.ptr);
		return print_reply(line);
	};
}

<* The method a one-shot command sends; the name is in temporary memory of the caller's pool. *>
fn String request_method(options::Options opts) @private
{
	if (opts.command == "list") return "services";
	if (opts.command == "state") return string::tformat("%s.state", opts.target);
	if (opts.command == "caps") return string::tformat("%s.capabilities", opts.target);
	return opts.target;
}

<* The params a one-shot command sends: `{}` except for `call`. *>
fn String request_params(options::Options opts) @private
{
	return opts.command == "call" ? opts.params : "{}";
}

<*
 Print the result of a reply line, or its error. `line` is `{"id":N,"result":...}`
 or `{"id":N,"error":"..."}`.

 @return "The exit code"
*>
fn int print_reply(String line) @private
{
	if (line.contains("\"result\":"))
	{
		print_pretty(fragment(line, "\"result\":", 1));
		return 0;
	}
	io::eprintfn("bleuctl: %s", reply_error(line));
	return 1;
}

<* The error text of an error frame, or a note when the frame has none. *>
fn String reply_error(String line) @private
{
	@pool()
	{
		Object*? frame = std::encoding::json::tparse(line);
		if (try root = frame)
		{
			if (try text = bleu::json::read::get_string(root, "error")) return text.copy(mem);
		}
		return "the reply has neither a result nor an error".copy(mem);
	};
}

<* The JSON value that follows `key` in a frame, without the `closing` brackets of the frame. *>
fn String fragment(String line, String key, usz closing) @private
{
	usz start = (usz)(line.index_of(key) ?? 0);
	start += key.len;
	return line[start:line.len - closing - start];
}

<* Print a JSON value pretty, on stdout. *>
fn void print_pretty(String compact) @private
{
	DString out;
	out.init(tmem);
	pretty::format(compact, &out);
	io::printn(out.str_view());
}

<*
 Subscribe to one service and print each state the daemon sends, until the
 connection ends or the process is interrupted.
*>
fn int? watch(ipc::client::Client* client, String service)
{
	String[1] names = { service };
	client.subscribe(names[..], REQUEST_TIMEOUT)!;
	while (true)
	{
		String line = client.next_line(FOREVER_LIMIT)!;
		defer alloc::free(mem, line.ptr);
		@pool()
		{
			if (line.contains("\"service\":")) print_pretty(fragment(line, "\"data\":", 2));
		};
	}
	return 0;
}

<* How long a watch waits for the next frame: one hour, which is as good as forever for a CLI. *>
const Duration FOREVER_LIMIT = (Duration)3_600_000_000;