<*
 One operation as the worker receives it. The strings are copied into the
 operation's own arena before the request is posted, so they stay valid until
 the worker completes `op` and releases its reference.

 Only the fields a command reads are meaningful; the rest are zero or empty.
*>
module bleu::bluetooth;
import bleu::operation;

<* A request for the worker. `op` is a reference the worker releases when it is done. *>
struct Request
{
	Command kind;
	String adapter; // adapter address; "" selects the first controller
	String device; // device address
	String text; // profile UUID, alias or discovery pattern
	bool flag; // the value a SET_ command writes, or the answer of REPLY_PAIRING
	uint number; // a timeout in seconds, or a passkey answer
	ulong ticket; // the pairing request a REPLY_PAIRING answers
	Profile profile;
	DiscoveryFilter filter;
	Operation{Done}* op;
}

<* A copy of `text` in `allocator`; the empty string needs no storage, and a zero-length copy is not made. *>
fn String copy_text(String text, Allocator allocator)
{
	if (text.len == 0) return "";
	return text.copy(allocator);
}