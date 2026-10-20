<*
 Change notification for the Linux catalogue: one inotify instance, watching the
 application directories. A watch reports that *something* changed; the backend
 then rescans the whole catalogue, which is what the contract asks for.

 Sources: inotify(7) and the kernel UAPI header `include/uapi/linux/inotify.h`
 (torvalds/linux on GitHub, raw file), cross-checked against glibc's
 `sys/inotify.h` (values of IN_CREATE, IN_DELETE, IN_MOVED_TO, IN_Q_OVERFLOW ...).
 `IN_NONBLOCK` and `IN_CLOEXEC` are the `O_NONBLOCK` (04000) and `O_CLOEXEC`
 (02000000) values, as the UAPI header defines them.
*>
module bleu::apps::xdg_watch @feat(LINUX);
import bleu::error, libc;

const int IN_CLOSE_WRITE  = 0x00000008;
const int IN_ATTRIB       = 0x00000004;
const int IN_CREATE       = 0x00000100;
const int IN_DELETE       = 0x00000200;
const int IN_DELETE_SELF  = 0x00000400;
const int IN_MOVED_FROM   = 0x00000040;
const int IN_MOVED_TO     = 0x00000080;
const int IN_MOVE_SELF    = 0x00000800;
const int IN_ONLYDIR      = 0x01000000;
const int IN_NONBLOCK     = 0x00000800;
const int IN_CLOEXEC      = 0x00080000;

<* Every event that can change which desktop files exist, or what they say. *>
const int WATCH_MASK = IN_CLOSE_WRITE | IN_ATTRIB | IN_CREATE | IN_DELETE | IN_DELETE_SELF
	| IN_MOVED_FROM | IN_MOVED_TO | IN_MOVE_SELF | IN_ONLYDIR;

const usz EVENT_BUFFER = 4096; // enough for many events; each is 16 bytes plus its name

extern fn int inotify_init1(int flags);
extern fn int inotify_add_watch(int fd, ZString path, uint mask);
extern fn long read(int fd, void* buf, usz count);

<*
 An inotify instance. Non-blocking; `drain` never waits.
*>
struct Watcher
{
	int fd;
}

<*
 Create the inotify instance.

 @return? error::BACKEND_FAILURE : "The kernel refused inotify_init1"
*>
fn void? Watcher.open(&self)
{
	int fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
	if (fd < 0) return error::raise(error::BACKEND_FAILURE, error::Domain.ERRNO, (int)libc::errno(), "inotify_init1 failed")~;
	self.fd = fd;
}

<* Whether the instance exists (`open` succeeded and `close` has not run). *>
fn bool Watcher.is_open(&self) @inline => self.fd >= 0;

<* Close the instance. Watches go with it. *>
fn void Watcher.close(&self)
{
	if (!self.is_open()) return;
	libc::close(self.fd);
	self.fd = -1;
}

<*
 Watch a directory for the events in `WATCH_MASK`. Watching a directory that is
 already watched is harmless: the kernel returns the same watch.

  @return? error::PERMISSION_DENIED : "The directory cannot be read"
 @return? error::BACKEND_FAILURE : "The kernel refused the watch for another reason"
*>
fn void? Watcher.watch(&self, String directory)
{
	if (inotify_add_watch(self.fd, directory.zstr_tcopy(), WATCH_MASK) >= 0) return;
	return error::raise(error::BACKEND_FAILURE, error::Domain.ERRNO, (int)libc::errno(), "cannot watch %s", directory)~;
}

<*
 Read and discard everything queued, without waiting.

 @return "true when at least one event was queued, so the catalogue may have changed"
*>
fn bool Watcher.drain(&self)
{
	if (!self.is_open()) return false;
	char[EVENT_BUFFER] events;
	bool seen = false;
	while (true)
	{
		long n = read(self.fd, &events, events.len);
		if (n <= 0) return seen;
		seen = true;
	}
}
