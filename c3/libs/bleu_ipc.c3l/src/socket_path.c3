<*
 Where the socket lives, and the process-level rules around it.

 The default path is `$XDG_RUNTIME_DIR/<app>-<pid>.sock`, the name dankgo uses
 (paths/paths.go:30-52). When `XDG_RUNTIME_DIR` is unset the server fails with
 UNAVAILABLE; DMS would fall back to `/run/<app>` or the temp directory, and this
 library does not guess (see the README).

 Sockets of processes that no longer exist are removed when a server starts
 (dankgo ipc/server.go:224-251). A process counts as gone only when kill(2) says
 ESRCH; a process that exists but belongs to someone else keeps its socket.
*>
module bleu::ipc @feat(POSIX);
import std::io, std::os::posix, std::os::env, libc, bleu::error, bleu::rt::fs;

// chmod(2) and kill(2): std has no binding for either.
extern fn CInt sys_chmod(ZString path, CUInt mode) @cname("chmod");
extern fn CInt sys_kill(CInt pid, CInt signal) @cname("kill");

<* The mode of a socket: owner read and write only (dankgo ipc/server.go:78). *>
const CUInt OWNER_ONLY_MODE = 0o600;

<* Signal number that tests a process without signalling it. *>
const CInt SIGNAL_NONE = 0;

<* Suffix of a socket file name. *>
const String SOCKET_SUFFIX = ".sock";

<*
 The path to bind: `config.socket_path` when set, otherwise
 `$XDG_RUNTIME_DIR/<app>-<pid>.sock`, after removing stale sockets next to it.

 @return "The path, owned by the caller"
 @return? error::UNAVAILABLE : "XDG_RUNTIME_DIR is not set or empty"
*>
fn String? resolve_socket_path(Allocator allocator, Config config) @private
{
	if (config.socket_path.len > 0) return config.socket_path.copy(allocator);
	String? dir = runtime_dir(allocator);
	if (catch err = dir) return err~;
	String directory = dir;
	long pid = (long)posix::getpid();
	remove_stale_sockets(directory, config.app_name, pid);
	String path;
	@pool()
	{
		path = string::tformat("%s/%s-%d%s", directory, config.app_name, pid, SOCKET_SUFFIX).copy(allocator);
	};
	alloc::free(allocator, directory.ptr);
	return path;
}

// `$XDG_RUNTIME_DIR` as a copy owned by `allocator`, or UNAVAILABLE.
fn String? runtime_dir(Allocator allocator) @private
{
	String? value = env::get_var(allocator, "XDG_RUNTIME_DIR");
	if (catch err = value)
	{
		return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "XDG_RUNTIME_DIR is not set; pass a socket path")~;
	}
	String dir = value;
	if (dir.len == 0)
	{
		alloc::free(allocator, dir.ptr);
		return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "XDG_RUNTIME_DIR is empty; pass a socket path")~;
	}
	return dir;
}

// Remove `<app>-<pid>.sock` files in `dir` whose process is gone. `own_pid` is never removed.
fn void remove_stale_sockets(String dir, String app, long own_pid) @private
{
	@pool()
	{
		if (try entries = fs::list_dir(tmem, dir))
		{
			for (sz i = 0; i < entries.len(); i++)
			{
				String name = (String)entries.get(i);
				long pid = socket_owner(name, app);
				if (pid <= 0 || pid == own_pid || process_exists(pid)) continue;
				if (catch io::path::delete((io::path::Path)string::tformat("%s/%s", dir, name))) {}
			}
		}
	};
}

<*
 The pid in a socket file name `<app>-<pid>.sock`, or -1 when the name has another shape.
*>
fn long socket_owner(String name, String app) @private
{
	usz prefix = app.len + 1;
	usz suffix = SOCKET_SUFFIX.len;
	if (name.len <= prefix + suffix) return -1;
	if (!name.starts_with(app) || name[app.len] != '-' || !name.ends_with(SOCKET_SUFFIX)) return -1;
	String digits = name[prefix : name.len - prefix - suffix];
	long pid = 0;
	for (sz i = 0; i < digits.len; i++)
	{
		char c = digits[i];
		if (!c.is_digit()) return -1;
		pid = pid * 10 + (long)(c - '0');
	}
	return pid;
}

// Whether a process with this pid exists. EPERM means it exists under another user.
fn bool process_exists(long pid) @private
{
	if (sys_kill((CInt)pid, SIGNAL_NONE) == 0) return true;
	return libc::errno() != ESRCH;
}

// Make a path owner-only. Returns 0 on success, as chmod(2) does.
fn CInt chmod_owner_only(String path) @private
{
	ZString zpath = path.zstr_copy(mem);
	defer alloc::free(mem, zpath);
	return sys_chmod(zpath, OWNER_ONLY_MODE);
}
