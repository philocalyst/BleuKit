module bleu::secrets::wipe_test;
import bleu::operation, bleu::secrets::wipe;

// Stands in for the backing allocator. It remembers every block it hands out, and
// before each release it checks that the payload of that block is all zeros.
const sz TRACKED = 32;

struct Recorder (Allocator)
{
	Allocator inner;
	void*[TRACKED] blocks;
	sz[TRACKED] sizes;
	sz count;
	sz payloads_checked;
	sz nonzero_payloads;
}

fn void*? Recorder.acquire(&self, sz size, AllocInitType init_type, sz alignment) @dynamic
{
	void* p = self.inner.acquire(size, init_type, alignment)!;
	if (self.count < TRACKED)
	{
		self.blocks[self.count] = p;
		self.sizes[self.count] = size;
		self.count++;
	}
	return p;
}

fn void*? Recorder.resize(&self, void* ptr, sz new_size, sz alignment) @dynamic
{
	return self.inner.resize(ptr, new_size, alignment);
}

fn void Recorder.release(&self, void* ptr, bool aligned) @dynamic
{
	for (sz i = 0; i < self.count; i++)
	{
		if (self.blocks[i] != ptr) continue;
		// The inner block is the header followed by the payload.
		char* bytes = (char*)ptr;
		self.payloads_checked++;
		for (sz j = wipe::HEADER_SIZE; j < self.sizes[i]; j++)
		{
			if (bytes[j] != 0) self.nonzero_payloads++;
		}
		break;
	}
	self.inner.release(ptr, aligned);
}

fn void payload_is_zero_when_released() @test
{
	Recorder recorder      = { .inner = mem };
	WipingAllocator wiping = { .inner = &recorder };
	char* payload          = (char*)wiping.acquire(40, ZERO, 0)!!;
	for (int i = 0; i < 40; i++) payload[i] = (char)(0xA5 ^ i);
	wiping.release(payload, false);
	assert(recorder.payloads_checked == 1, "the released block was seen");
	assert(recorder.nonzero_payloads == 0, "the payload must be zeroed before the inner release");
}

fn void arena_pages_are_wiped_on_free() @test
{
	Recorder recorder      = { .inner = mem };
	WipingAllocator wiping = { .inner = &recorder };
	DynamicArenaAllocator arena;
	arena.init(&wiping, 256);
	char* first = (char*)arena.acquire(100, NO_ZERO, 0)!!;
	first[0] = 0x7E;
	first[99] = 0x7E;
	arena.free();
	assert(recorder.payloads_checked >= 2, "the arena's blocks were released through the wrapper");
	assert(recorder.nonzero_payloads == 0, "no arena block keeps its bytes after the free");
}

fn void resize_keeps_the_prefix() @test
{
	WipingAllocator wiping = { .inner = mem };
	char* p                = (char*)wiping.acquire(4, NO_ZERO, 0)!!;
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
// An operation can outlive the keyring that made it: its memory stays valid until the operation is
// released, and the arena is freed only then. Run under valgrind, a use after the close would show.
fn void operation_outlives_arena_close() @test
{
	OperationArena* arena = open_arena(mem);
	Operation{bool}* op = operation::begin{bool}(arena);
	Allocator op_arena = op.allocator();
	String text = "a secret that lives in the operation".copy(op_arena);
	arena.close();
	assert(text == "a secret that lives in the operation");
	op.succeed(true);
	op.release();
}

// A closed arena with nothing outstanding is freed at once; it must not be used after that.
fn void idle_arena_frees_on_close() @test
{
	OperationArena* arena = open_arena(mem);
	arena.close();
}
