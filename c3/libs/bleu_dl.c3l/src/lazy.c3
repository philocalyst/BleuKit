<*
 A table that is bound on first use and then shared by everyone who asks.

 Several services use the same native table (brightness and display both need
 the DisplayServices table). A `Lazy{Table}` is declared once, as a module
 global, and every user calls `get` with the candidates. The first caller
 binds; concurrent callers wait for it to finish; everyone afterwards gets the
 same pointer without locking.

 The outcome is cached, success or failure. A failed bind is not retried
 (retrying would only repeat the same `dlopen` and the same failure); callers
 get the failure with its loader message again.

 The library is never closed: pointers into it may be held for the life of the
 process.
*>
module bleu::dl::lazy <Table>;
import std::thread, std::atomic, bleu::error, bleu::dl;

<* The states of a lazy table, stored as an `int` in an `Atomic`. *>
const int UNBOUND = 0;
const int BINDING = 1;
const int BOUND = 2;
const int FAILED = 3;

<*
 One table, bound at most once. Declare it as a global.
*>
struct Lazy
{
	Atomic{int} phase;
	Library library;
	Table table;
	error::Detail failure;
}

<*
 The bound table, binding it from `candidates` on the first call.

 @param [&inout] candidates : "Library names or paths, used only by the first call"
 @return? UNAVAILABLE : "The library could not be opened (the outcome is cached)"
 @return? UNSUPPORTED : "A required symbol is missing (the outcome is cached)"
*>
fn Table*? Lazy.get(&self, String[] candidates)
{
	int claimed = UNBOUND;
	if (self.phase.compare_exchange(&claimed, BINDING)) self.bind(candidates);
	// Another thread is binding: the work is one dlopen, so yielding is enough.
	while (self.phase.load() == BINDING) thread::yield();
	if (self.phase.load() == FAILED)
	{
		*error::last() = self.failure;
		return error::fault_of(self.failure.status)~;
	}
	return &self.table;
}

// Called by the one thread that won the claim on `phase`.
fn void Lazy.bind(&self, String[] candidates)
{
	Library? opened = dl::open(candidates);
	if (catch opened)
	{
		self.record_failure();
		return;
	}
	self.library = opened!!;
	if (catch dl::bind(&self.table, &self.library))
	{
		self.library.close();
		self.record_failure();
		return;
	}
	self.phase.store(BOUND);
}

fn void Lazy.record_failure(&self)
{
	self.failure = *error::last();
	self.phase.store(FAILED);
}
