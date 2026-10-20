module bleu::objc::block_layout;

// Offsets are checked at run time: C3 0.8.5 has no offsetof, and the sizes are checked with $assert in the module.
fn void literal_offsets() @test
{
	BlockLiteral literal = { };
	usz base             = (usz)&literal;
	assert((usz)&literal.isa - base == 0);
	assert((usz)&literal.flags - base == 8);
	assert((usz)&literal.reserved - base == 12);
	assert((usz)&literal.invoke - base == 16);
	assert((usz)&literal.descriptor - base == 24);
	assert((usz)&literal.context - base == 32);
}

// Block_descriptor_2: reserved, size, copy, dispose (libclosure Block_private.h).
fn void descriptor_offsets() @test
{
	BlockDescriptor descriptor = { };
	usz base                   = (usz)&descriptor;
	assert((usz)&descriptor.reserved - base == 0);
	assert((usz)&descriptor.size - base == 8);
	assert((usz)&descriptor.copy_helper - base == 16);
	assert((usz)&descriptor.dispose_helper - base == 24);
}

fn void context_offsets() @test
{
	BlockContext context = { };
	usz base             = (usz)&context;
	assert((usz)&context.refs - base == 0);
	assert((usz)&context.callback - base == 8);
	assert((usz)&context.user - base == 16);
}

// BLOCK_HAS_COPY_DISPOSE = 1 << 25 (Block_private.h).
fn void flag_value() @test
{
	assert(BLOCK_HAS_COPY_DISPOSE == 33554432);
}