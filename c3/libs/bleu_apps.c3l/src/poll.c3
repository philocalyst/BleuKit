<*
 Change detection for backends that cannot watch their directories (macOS and
 Windows in this version): every `interval` the application directories are
 listed, and the catalogue is rescanned when their names changed or a command
 asked for it. Renames of files inside a bundle or a shortcut's folder are not
 seen until the directory itself changes or a REFRESH arrives.
*>
module bleu::apps;
import std::time, std::io::path, bleu::rt::fs, bleu::rt::poller, bleu::error, bleu::rt::worker, bleu::service, bleu::stream, bleu::observe;

<* Rescans the catalogue of one polled backend, on the worker thread. *>
alias PolledRefreshFn = fn void(void* state, AppsHub* hub);

<*
 A text that changes whenever a directory gains or loses an entry: the names of
 every entry of every directory, in listing order. Allocated from `allocator`.

 @return? NOT_FOUND, error::PERMISSION_DENIED, error::BACKEND_FAILURE : "A directory could not be listed"
*>
fn String? fingerprint(String[] directories, Allocator allocator)
{
	DString text;
	text.init(tmem);
	foreach (directory : directories)
	{
		PathList? names = fs::list_dir(tmem, directory);
		if (catch err = names)
		{
			// A directory that cannot be listed contributes nothing; its absence is a change in itself.
			text.append_string(directory);
			text.append_string("!\n");
			continue;
		}
		foreach (name : names)
		{
			text.append_string(name);
			text.append_string("\n");
		}
	}
	return text.copy_str(allocator);
}

<*
 Run a polled backend's worker loop: refresh once, then wait `interval` or a
 command, serve commands, and refresh when the directories or a REFRESH say so.
*>
fn void run_polled(
	void* state,
	AppsHub* hub,
	AppsHost* host,
	Duration interval,
	String[] directories,
	PolledRefreshFn refresh,
	LaunchFn launch
)
{
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	refresh(state, hub);
	String last = fingerprint(directories, mem) ?? "";
	while (!host.stopping())
	{
		if (catch err = poller.wait(interval))
		{
			// TIMEOUT is the normal tick; anything else means the OS wait itself failed.
			if (err != TIMEOUT) break;
		}
		bool refresh_now = false;
		serve(state, hub, host, launch, &refresh_now);
		String now = fingerprint(directories, mem) ?? "";
		if (refresh_now || now != last) refresh(state, hub);
		alloc::free(mem, last.ptr);
		last = now;
	}
	alloc::free(mem, last.ptr);
	refuse_pending(host);
}