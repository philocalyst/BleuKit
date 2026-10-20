<*
 An allocator whose blocks are zeroed before they are given back.

 Secret bytes live in operation arenas, and an arena frees its pages through
 its backing allocator without telling it their sizes. `WipingAllocator` keeps
 the size of every block in a small header in front of it, so that `release`
 can overwrite the payload with volatile stores before the memory is freed.
 Pages of an arena are therefore zeroed when the arena is freed.

 Limits: the zeroing covers the block itself, not copies made elsewhere (a
 `String` copied out of it, registers, the swap file before the free). Blocks
 with an alignment above `HEADER_SIZE` are refused, because the header must sit
 directly in front of the payload.
*>
module bleu::secrets::wipe;
import std::thread;

<* Bytes reserved in front of every payload; wide enough to keep the payload 16-byte aligned. *>
const sz HEADER_SIZE = 16;

<* Alignment the header guarantees for the payload. *>
const sz MAX_ALIGNMENT = 16;

<*
 Stores the payload size in front of each block and zeroes the payload on release.
 Wraps `inner`; a zero-initialised value is not usable until `inner` is set.
*>
struct WipingAllocator (Allocator)
{
	Allocator inner;
}

<* The size recorded in front of a payload. *>
struct Header
{
	sz size;
	sz reserved;
}

fn void*? WipingAllocator.acquire(&self, sz size, AllocInitType init_type, sz alignment) @dynamic
{
	if (alignment > MAX_ALIGNMENT) return mem::INVALID_ALLOC_SIZE~;
	// The payload is zeroed on release anyway, so the inner block is always zeroed here.
	char* base     = (char*)self.inner.acquire(HEADER_SIZE + size, ZERO)!;
	Header* header = (Header*)base;
	header.size = size;
	return base + HEADER_SIZE;
}

fn void*? WipingAllocator.resize(&self, void* ptr, sz new_size, sz alignment) @dynamic
{
	if (alignment > MAX_ALIGNMENT) return mem::INVALID_ALLOC_SIZE~;
	void* fresh = self.acquire(new_size, NO_ZERO, alignment)!;
	sz old_size = header_of(ptr).size;
	mem::copy(fresh, ptr, min(old_size, new_size));
	self.release(ptr, alignment > 0);
	return fresh;
}

fn void WipingAllocator.release(&self, void* ptr, bool aligned) @dynamic
{
	// The inner block was acquired without an alignment requirement, so it is released without one.
	Header* header = header_of(ptr);
	zero(ptr, header.size);
	self.inner.release((char*)header, false);
	(void)aligned;
}

<* The header in front of a payload previously returned by `acquire`. *>
fn Header* header_of(void* ptr) @inline => (Header*)((char*)ptr - HEADER_SIZE);

<* Overwrite `len` bytes at `ptr` with zeros; volatile so the compiler may not drop the stores. *>
fn void zero(void* ptr, sz len) @inline
{
	if (len == 0) return;
	mem::set(ptr, 0, len, 0, true);
}
<*
 The allocator that every operation of a keyring takes its memory from. It outlives the keyring: a
 `close` only marks it closed, and its memory is freed when the last block it handed out has been
 released, so an operation the caller still holds stays valid after `Keyring.close`.

 It counts the blocks it has handed out and not yet released. Its own memory is allocated from the
 keyring's allocator, and freed by whichever call comes last: `close`, or the last `release` after it.
*>
struct OperationArena (Allocator)
{
	WipingAllocator wiper; // zeroes the blocks; its `inner` is the keyring's allocator
	Mutex lock;
	usz live; // blocks handed out and not yet released
	bool closed; // the keyring has been closed: no more blocks are wanted
}

<* A new arena over `allocator`, to be closed with `close` once the keyring is done with it. *>
fn OperationArena* open_arena(Allocator allocator)
{
	OperationArena* arena = alloc::new(allocator, OperationArena, { .wiper = { .inner = allocator } });
	arena.lock.init()!!;
	return arena;
}

fn void*? OperationArena.acquire(&self, sz size, AllocInitType init_type, sz alignment) @dynamic
{
	self.lock.lock()!!;
	defer self.lock.unlock();
	void* ptr = self.wiper.acquire(size, init_type, alignment)!;
	self.live++;
	return ptr;
}

fn void*? OperationArena.resize(&self, void* ptr, sz new_size, sz alignment) @dynamic
{
	// A resize keeps one block in place of another, so the count does not change.
	self.lock.lock()!!;
	defer self.lock.unlock();
	return self.wiper.resize(ptr, new_size, alignment);
}

fn void OperationArena.release(&self, void* ptr, bool aligned) @dynamic
{
	self.lock.lock()!!;
	self.wiper.release(ptr, aligned);
	self.live--;
	bool idle = self.closed && self.live == 0;
	self.lock.unlock();
	if (idle) free_arena(self);
}

<*
 The keyring is closed. Nothing new is allocated from the arena after this. Its memory is freed now when
 no block is outstanding, and otherwise by the release of the last one.
*>
fn void OperationArena.close(&self)
{
	self.lock.lock()!!;
	self.closed = true;
	bool idle = self.live == 0;
	self.lock.unlock();
	if (idle) free_arena(self);
}

// Frees the arena and its lock. Entered only when the arena is closed and no block is outstanding.
fn void free_arena(OperationArena* arena) @private
{
	Allocator inner = arena.wiper.inner;
	arena.lock.destroy();
	alloc::free(inner, arena);
}