<*
 Change detection for backends that cannot watch their directories (macOS and
 Windows in this version): every `interval` the application directories are
 listed, and the catalogue is rescanned when their names changed or a command
 asked for it. Renames of files inside a bundle or a shortcut's folder are not
 seen until the directory itself changes or a REFRESH arrives.
*>
module bleu::apps;
import std::time, std::time::clock, std::io::path, bleu::rt::fs, bleu::rt::poller, bleu::error, bleu::rt::worker, bleu::service, bleu::stream, bleu::observe;

<*
 The longest a changed catalogue waits before it is rescanned, however often the directory
 keeps changing. Without it, a directory written more often than the quiet period is never rescanned.
*>
const Duration MAX_CHANGE_DELAY = (Duration)2_000_000;

<* Microseconds from `from` to `to` on the monotonic clock; zero when `to` is not later. *>
fn Duration micros_between(Clock from, Clock to)
{
	if (to <= from) return time::DURATION_ZERO;
	return (Duration)(((ulong)to - (ulong)from) / 1000);
}

<*
 How long a changed catalogue may still wait before its rescan: until it has been quiet for `settle`,
 and no later than `cap` after its first change. Zero means the rescan is due now. Pure.
*>
fn Duration rescan_wait(Clock first_change, Clock last_change, Clock now, Duration settle, Duration cap)
{
	Duration quiet = settle - micros_between(last_change, now);
	Duration limit = cap - micros_between(first_change, now);
	if (quiet < time::DURATION_ZERO) quiet = time::DURATION_ZERO;
	if (limit < time::DURATION_ZERO) limit = time::DURATION_ZERO;
	return quiet < limit ? quiet : limit;
}

<*
 The fingerprint text of one directory listing: the names in byte order, one per line, so the same
 set of names always gives the same text whatever order the system listed them in. Pure.
*>
fn String listing_text(String[] names, Allocator allocator)
{
	String[] sorted = alloc::clone_slice(tmem, names);
	for (usz i = 1; i < sorted.len; i++)
	{
		String current = sorted[i];
		usz j          = i;
		while (j > 0 && sorted[j - 1].compare_to(current) > 0)
		{
			sorted[j] = sorted[j - 1];
			j--;
		}
		sorted[j] = current;
	}
	DString text;
	text.init(tmem);
	foreach (name : sorted)
	{
		text.append_string(name);
		text.append_string("\n");
	}
	return text.copy_str(allocator);
}

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
		String[] listed = alloc::new_array(tmem, String, names.len());
		foreach (i, name : names) listed[i] = (String)name;
		text.append_string(listing_text(listed, tmem));
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