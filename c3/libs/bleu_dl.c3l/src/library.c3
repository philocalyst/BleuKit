<*
 Run-time access to shared libraries and the symbols they export.

 The linker binds a program to a library at build time, so a missing library
 or a symbol renamed in a later OS release would stop the whole program from
 starting. The private and optional native APIs Bleu relies on are therefore
 resolved here, when the service needs them, through the platform loader:
 `dlopen`/`dlsym` on POSIX, `LoadLibraryExW`/`GetProcAddress` on Windows.
 See docs/research/bleu_dl.md for the sources and the rules.

 Every failure is a fault from the Bleu vocabulary, and the loader's own text
 is in `error::last()`.
*>
module bleu::dl;
import std::os, bleu::error, bleu::dl::native;

<*
 A shared object, or the program itself, opened at run time.

 `Library` is a value: keep it in the service that uses it, and close it only
 when nothing can call into it any more (see `close`).
*>
struct Library
{
	DylibHandle handle;
	String name;          // The candidate that opened, copied at open time
	bool is_program;      // The main program: never unloaded
}

<*
 The options used when no others are given. On Windows, only the system
 directories and the application's own directory are searched
 (`LOAD_LIBRARY_SEARCH_DEFAULT_DIRS`), so a planted DLL in the current
 directory is never loaded. POSIX ignores the flag.
*>
const DylibOpenOptions DEFAULT_OPTIONS = { .safe_search = true };

<*
 Open the first candidate the platform loader accepts. Candidates are tried in
 order. A bare name ("libpulse.so.0", "dwmapi.dll") lets the loader search its
 usual places; a path names one file, and it is opened even if the path
 exists only in the dyld shared cache (macOS).

 The library stays loaded until `close`, and the loader resolves the library's
 own dependencies lazily, so an unrelated missing dependency symbol does not
 stop the library from opening.

 @param candidates : "Library names or paths, in order of preference"
 @param options : "How the library is loaded; see `DylibOpenOptions`"
 @require candidates.len > 0 : "at least one candidate is required"
 @return? error::UNAVAILABLE : "No candidate could be loaded; the message names the last one tried and the loader's reason"
*>
fn Library? open(String[] candidates, DylibOpenOptions options = DEFAULT_OPTIONS)
{
	@pool()
	{
		native::Failure failure;
		foreach (name : candidates)
		{
			DylibHandle handle = std::os::dlopen(name.zstr_tcopy(), options);
			if (handle) return { .handle = handle, .name = name.copy(mem) };
			failure = native::last_failure();
		}
		return error::raise(error::UNAVAILABLE, failure.domain, failure.code,
			"no library loadable from %d candidate(s), last '%s': %s",
			candidates.len, candidates[^1], failure.text)~;
	};
}

<*
 Open the program itself: the symbols of the executable and of the libraries
 it was linked with (`dlopen(NULL)` on POSIX, `GetModuleHandle(NULL)` on
 Windows). Use it for symbols that the platform guarantees to be loaded, such
 as libc on POSIX.

 @return? error::UNAVAILABLE : "The loader does not expose the program's handle"
*>
fn Library? main_program()
{
	@pool()
	{
		DylibHandle handle;
		$if env::WIN32:
			handle = (DylibHandle)std::os::win32::getModuleHandleA(null);
		$else
			handle = std::os::dlopen(null);
		$endif
		if (!handle)
		{
			native::Failure failure = native::last_failure();
			return error::raise(error::UNAVAILABLE, failure.domain, failure.code,
				"cannot obtain the main program's handle: %s", failure.text)~;
		}
		return { .handle = handle, .name = "the main program".copy(mem), .is_program = true };
	};
}

<*
 Unload the library, or for the main program only forget it, and free its
 name.

 Unsafe: after `close`, every function pointer and address obtained from this
 library dangles. Close only when no code can still run from it, and only
 after every callback the library was given has been unregistered. Libraries
 that are used for the life of the process should simply never be closed.
*>
fn void Library.close(&self)
{
	if (!self.handle) return;
	if (!self.is_program) self.handle.close();
	alloc::free(mem, self.name.ptr);
	*self = {};
}

<*
 The address of `name` in this library, or null when it does not export it.
 Absence is an ordinary answer for an optional symbol, so nothing is recorded
 in `error::last()`; use `symbol` when absence is an error.

 @require !!self.handle : "the library is closed"
*>
fn void* Library.find(&self, String name)
{
	void* address;
	@pool()
	{
		address = std::os::dlsym(self.handle, name.zstr_tcopy());
	};
	return address;
}

<*
 Whether this library exports `name`.

 @require !!self.handle : "the library is closed"
*>
fn bool Library.has(&self, String name) => self.find(name) != null;

<*
 The address of `name`, or `NOT_FOUND` naming the symbol, the library and the
 loader's reason.

 @require !!self.handle : "the library is closed"
 @return? NOT_FOUND : "The library does not export `name`"
*>
fn void*? Library.symbol(&self, String name)
{
	void* address;
	@pool()
	{
		address = self.find(name);
		if (!address)
		{
			native::Failure failure = native::last_failure();
			return error::raise(NOT_FOUND, failure.domain, failure.code,
				"symbol '%s' not found in %s: %s", name, self.name, failure.text)~;
		}
	};
	return address;
}
