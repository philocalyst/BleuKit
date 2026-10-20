<*
 Objective-C blocks built from C3 (Apple Block ABI, ABI.2010.3.16).

 A block is a struct whose first fields are fixed by the ABI:

     struct Block_literal {
         void *isa;          // &_NSConcreteStackBlock, then the heap class after _Block_copy
         int   flags;        // BLOCK_HAS_COPY_DISPOSE (1 << 25) is set here
         int   reserved;     // 0
         void *invoke;       // called with the block pointer as first argument
         struct Block_descriptor *descriptor;
         /* captured variables follow */
     };

 Sources (cross-checked):
   * Apple, "Block Implementation Specification", clang.llvm.org/docs/Block-ABI-Apple.html
     (struct layout, flag bits, `_Block_copy`/`_Block_object_assign` helper contract).
   * Rust `block2` 0.5.1, `src/abi.rs` (flag values, `_NSConcreteStackBlock`) and
     `src/ffi.rs` (`_Block_copy`, `_Block_release` as libSystem exports).

 Design: C3 cannot capture variables, so the captured state is a single
 `BlockContext` pointer holding a C3 function pointer and its user pointer.
 `BlockContext` is reference counted: the block's copy helper adds a reference
 and its dispose helper removes one, so the context lives exactly as long as
 the heap block(s) that point at it.

 Lifetime, precisely:
   * `void_block`, `id_block`, `bool_error_block`, `id_error_block` and `int_block` return a heap block with one reference (owned by the caller).
   * Passing `block.id()` to an API that keeps the handler retains it (blocks
     answer `copy`/`retain`), exactly as with a compiler-generated block.
   * `block.release()` drops the caller's reference (`_Block_release`). When the
     last reference goes, the runtime calls `block_dispose`, which frees the context.
   * A handler runs on whatever thread the framework calls it from. Handlers
     must not block and must only enqueue work (ARCHITECTURE.md: foreign callbacks).

 Arguments delivered to a handler are borrowed for the duration of the call.
 Keep one with `Obj.borrow(...)`.
*>
module bleu::objc @feat(DARWIN) @link("Foundation.framework");
import std::atomic, std::os::darwin::objc;

<* Flag bit: the descriptor carries copy and dispose helpers. Block-ABI-Apple.html, enum of flag bits. *>
const int BLOCK_HAS_COPY_DISPOSE = 1 << 25;

<* Argument of `copy_helper`: the destination and source block literals. *>
alias BlockCopyHelper = fn void(void* dst, void* src);

<* Argument of `dispose_helper`: the block literal being destroyed. *>
alias BlockDisposeHelper = fn void(void* src);

<* Block descriptor as laid out by the ABI (`struct Block_descriptor_1`). *>
struct BlockDescriptor
{
	ulong reserved;
	ulong size;
	BlockCopyHelper copy_helper;
	BlockDisposeHelper dispose_helper;
}

<* Block literal as laid out by the ABI, with one captured pointer. *>
struct BlockLiteral
{
	void* isa;
	int flags;
	int reserved;
	void* invoke;
	BlockDescriptor* descriptor;
	BlockContext* context;
}

<*
 The state every block created by this file captures. Reference count:
 starts at 1 for the creator; each heap copy adds one; each dispose removes one.
*>
struct BlockContext
{
	Atomic{int} refs;
	void* callback;
	void* user;
}

<* A handler that takes nothing: `void (^)(void)`. *>
alias VoidHandler = fn void(void* user);

<* A handler that takes one object: `void (^)(id)`. *>
alias IdHandler = fn void(void* user, ObjId value);

<* A handler that takes a BOOL and an error: `void (^)(BOOL, NSError *)`. *>
alias BoolErrorHandler = fn void(void* user, bool success, ObjId error);

<* A handler that takes an object and an error: `void (^)(id, NSError *)`. *>
alias IdErrorHandler = fn void(void* user, ObjId value, ObjId error);

<* A handler that takes an int: `void (^)(int)`. *>
alias IntHandler = fn void(void* user, int value);

<* Address of the runtime's stack-block class: the `isa` of a block literal built on the C stack. Symbol: libSystem. *>
extern const char NS_CONCRETE_STACK_BLOCK @cname("_NSConcreteStackBlock");

extern fn void* block_copy_raw(void* block) @cname("_Block_copy");
extern fn void block_release_raw(void* block) @cname("_Block_release");

<* One descriptor shared by every block this file makes. Its size is that of a `BlockLiteral`. *>
BlockDescriptor block_descriptor = {
	.size = BlockLiteral::size,
	.copy_helper = &block_copy,
	.dispose_helper = &block_dispose,
};

<*
 The owned handle to a heap block. `ptr` is the block object (an `id` in the
 Objective-C sense), so it can be passed wherever a block object is expected.
*>
struct Block
{
	void* ptr;
}

<* The block as an object argument (+0; the handle still owns it). *>
fn ObjId Block.id(self) @inline => (ObjId)self.ptr;

<* Drop the caller's reference and become empty. Idempotent. *>
fn void Block.release(&self)
{
	if (self.ptr) block_release_raw(self.ptr);
	self.ptr = null;
}

<* Copy helper: the runtime has already moved the literal bytes; only the context gains a reference. *>
fn void block_copy(void* dst, void* src)
{
	BlockLiteral* source = (BlockLiteral*)src;
	source.context.refs.add(1);
}

<* Dispose helper: drop a reference and free the context when none remain. *>
fn void block_dispose(void* src)
{
	BlockLiteral* source = (BlockLiteral*)src;
	if (source.context.refs.sub(1) == 1) alloc::free(mem, source.context);
}

<* Invoke for `void (^)(void)`. The runtime passes the block pointer first. *>
fn void invoke_void(BlockLiteral* block)
{
	BlockContext* context = block.context;
	((VoidHandler)context.callback)(context.user);
}

<* Invoke for `void (^)(id)`. *>
fn void invoke_id(BlockLiteral* block, ObjId value)
{
	BlockContext* context = block.context;
	((IdHandler)context.callback)(context.user, value);
}

<* Invoke for `void (^)(BOOL, NSError *)`. *>
fn void invoke_bool_error(BlockLiteral* block, bool success, ObjId error)
{
	BlockContext* context = block.context;
	((BoolErrorHandler)context.callback)(context.user, success, error);
}

<* Invoke for `void (^)(id, NSError *)`. *>
fn void invoke_id_error(BlockLiteral* block, ObjId value, ObjId error)
{
	BlockContext* context = block.context;
	((IdErrorHandler)context.callback)(context.user, value, error);
}

<* Invoke for `void (^)(int)`. *>
fn void invoke_int(BlockLiteral* block, int value)
{
	BlockContext* context = block.context;
	((IntHandler)context.callback)(context.user, value);
}

<*
 Build a heap block around `invoke`, `callback` and `user`. The literal is
 built on the C stack, copied to the heap by the runtime (which calls the copy
 helper), and the creator then drops its own context reference.
*>
fn Block make_block(void* invoke, void* callback, void* user) @local
{
	BlockContext* context = alloc::new(mem, BlockContext);
	context.refs.store(1);
	context.callback = callback;
	context.user = user;
	BlockLiteral literal = {
		.isa = (void*)&NS_CONCRETE_STACK_BLOCK,
		.flags = BLOCK_HAS_COPY_DISPOSE,
		.invoke = invoke,
		.descriptor = &block_descriptor,
		.context = context,
	};
	void* heap = block_copy_raw(&literal);
	if (context.refs.sub(1) == 1) alloc::free(mem, context);
	return { .ptr = heap };
}

<* A heap block for `void (^)(void)`. `user` is passed back to `handler`. *>
fn Block void_block(VoidHandler handler, void* user) => make_block((void*)&invoke_void, (void*)handler, user);

<* A heap block for `void (^)(id)`. *>
fn Block id_block(IdHandler handler, void* user) => make_block((void*)&invoke_id, (void*)handler, user);

<* A heap block for `void (^)(BOOL, NSError *)`. *>
fn Block bool_error_block(BoolErrorHandler handler, void* user) => make_block((void*)&invoke_bool_error, (void*)handler, user);

<* A heap block for `void (^)(id, NSError *)`. *>
fn Block id_error_block(IdErrorHandler handler, void* user) => make_block((void*)&invoke_id_error, (void*)handler, user);

<* A heap block for `void (^)(int)`. *>
fn Block int_block(IntHandler handler, void* user) => make_block((void*)&invoke_int, (void*)handler, user);
