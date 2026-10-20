<*
 Text ownership helpers shared by the backends. A backend keeps its own copies of the strings it
 stores (the caller's strings die with the call), so every stored string is made here and freed here.
 The empty string owns nothing and is never allocated or freed.
*>
module bleu::hotkey;

// A copy of `text` in `allocator`; the empty string needs no storage.
fn String text_copy(String text, Allocator allocator)
{
	if (text.len == 0) return "";
	return text.copy(allocator);
}

// Free a string made by `text_copy`.
fn void text_free(String text, Allocator allocator)
{
	if (text.len > 0) alloc::free(allocator, text.ptr);
}

// Copy `text` into `*field` with `allocator`, freeing the text it replaces.
fn void text_set(String* field, String text, Allocator allocator)
{
	text_free(*field, allocator);
	*field = text_copy(text, allocator);
}
