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