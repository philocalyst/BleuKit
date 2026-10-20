module bleu::secrets::wipe_test;
import bleu::secrets::wipe;

// Stands in for the backing allocator and checks the payload just before it is freed.
struct Recorder (Allocator)
{
	Allocator inner;
	void* base;
	sz size;
	bool was_zero_at_release;
}

fn void*? Recorder.acquire(&self, sz size, AllocInitType init_type, sz alignment) @dynamic
{
	void* p = self.inner.acquire(size, init_type, alignment)!;
	self.base = p;
	self.size = size;
	return p;
}

fn void*? Recorder.resize(&self, void* ptr, sz new_size, sz alignment) @dynamic
{
	return self.inner.resize(ptr, new_size, alignment);
}

fn void Recorder.release(&self, void* ptr, bool aligned) @dynamic
{
	if (ptr == self.base)
	{
		char* bytes = (char*)ptr;
		self.was_zero_at_release = true;
		for (sz i = 0; i < self.size; i++)
		{
			if (bytes[i] != 0) self.was_zero_at_release = false;
		}
	}
	self.inner.release(ptr, aligned);
}

fn void payload_is_zero_when_released() @test
{
	Recorder recorder = { .inner = mem };
	WipingAllocator wiping = { .inner = &recorder };
	char* payload = (char*)wiping.acquire(40, ZERO, 0)!!;
	for (int i = 0; i < 40; i++) payload[i] = (char)(0xA5 ^ i);
	wiping.release(payload, false);
	assert(recorder.was_zero_at_release, "the payload must be zeroed before the inner release");
}

fn void arena_pages_are_wiped_on_free() @test
{
	Recorder recorder = { .inner = mem };
	WipingAllocator wiping = { .inner = &recorder };
	DynamicArenaAllocator arena;
	arena.init(&wiping, 256);
	char* first = (char*)arena.acquire(100, NO_ZERO, 0)!!;
	first[0] = 0x7E;
	first[99] = 0x7E;
	arena.free();
	assert(recorder.was_zero_at_release, "the arena's page must be zeroed when the arena is freed");
}

fn void resize_keeps_the_prefix() @test
{
	WipingAllocator wiping = { .inner = mem };
	char* p = (char*)wiping.acquire(4, NO_ZERO, 0)!!;
	p[0] = 'a';
	p[3] = 'd';
	char* q = (char*)wiping.resize(p, 8, 0)!!;
	assert(q[0] == 'a' && q[3] == 'd');
	wiping.release(q, false);
}

fn void over_aligned_blocks_are_refused() @test
{
	WipingAllocator wiping = { .inner = mem };
	assert(@catch(wiping.acquire(16, NO_ZERO, 64)) == mem::INVALID_ALLOC_SIZE);
}
