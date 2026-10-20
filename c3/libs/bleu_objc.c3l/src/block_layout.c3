<*
 The memory layout of an Objective-C block built from C3 (Apple Block ABI,
 ABI.2010.3.16): the descriptor, the literal, and the context the literal captures.

 This module is pure data with no `@feat`, so every target compiles it and its
 `@test`s check the layout on Linux. `block.c3` (Darwin only) builds the blocks.

 Sources (cross-checked):
 * Apple, "Block Implementation Specification" (libclosure `Block_private.h`:
   `BLOCK_HAS_COPY_DISPOSE = 1 << 25`, `struct Block_descriptor_1 { reserved, size }`,
   `struct Block_descriptor_2` adds copy and dispose, and the literal fields
   `isa, flags, reserved, invoke, descriptor`).
 * Rust `block2` 0.5.1, `src/abi.rs` (the same flag value and field order).

 The ABI fixes the field order, so the sizes are checked with `$assert` and the
 offsets in `block_layout_test.c3` (C3 0.8.5 has no offsetof).
*>
module bleu::objc::block_layout;
import std::atomic;

<* Flag bit: the descriptor carries copy and dispose helpers (`BLOCK_HAS_COPY_DISPOSE`, Block_private.h). *>
const int BLOCK_HAS_COPY_DISPOSE = 1 << 25;

<* Argument of `copy_helper`: the destination and source block literals. *>
alias BlockCopyHelper = fn void(void* dst, void* src);

<* Argument of `dispose_helper`: the block literal being destroyed. *>
alias BlockDisposeHelper = fn void(void* src);

<* Block descriptor as laid out by the ABI (`struct Block_descriptor_2`): reserved, size, copy, dispose. *>
struct BlockDescriptor
{
	ulong reserved;
	ulong size;
	BlockCopyHelper copy_helper;
	BlockDisposeHelper dispose_helper;
}

<* Block literal as laid out by the ABI, with one captured pointer (`struct Block_layout`). *>
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

// Sizes on every target: pointers and `ulong` are 64 bits, `int` 32 bits.
// A `BlockLiteral` is isa(8) + flags(4) + reserved(4) + invoke(8) + descriptor(8) + context(8).
$assert(BlockDescriptor::size == 32);
$assert(BlockLiteral::size == 40);
$assert(BlockContext::size == 24);
