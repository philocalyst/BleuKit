<*
 Helpers every command uses to write its reply and to wait for its operation.
*>
module bleu::registry;
import std::time, bleu::error, bleu::json, bleu::operation;

<* Write the success object `{"ok": true}`. Commands add their own fields before it when they need to. *>
fn void? write_ok(json::JsonWriter* out)
{
	out.begin_object()!;
	out.key("ok")!;
	out.put_bool(true)!;
	return out.end_object();
}

<*
 Wait for `operation` to finish and return its value. When it is still running
 after `timeout` it is cancelled, so the worker stops at its next check.

 @param timeout : "Longest to wait; the command's own timeout"
 @return? TIMEOUT : "The operation did not finish in time; it was cancelled"
 @return? error::CANCELLED : "The operation was cancelled"
*>
fn Value? await(Operation{Value}* operation, Duration timeout)<Value>
{
	Value? value = operation.wait(timeout);
	if (catch err = value)
	{
		if (err == TIMEOUT) operation.cancel();
		String detail = operation.detail().message();
		if (!detail.len) detail = "the operation failed without a message";
		return error::raise(err, error::Domain.INTERNAL, 0, "%s", detail)~;
	}
	return value;
}
