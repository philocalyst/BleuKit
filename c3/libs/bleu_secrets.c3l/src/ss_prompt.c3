<*
 Running a Secret Service prompt: the keyring asks the user (for an unlock
 password, say) and reports the answer with the Completed signal.

 The wait is bounded. The crate this follows waits without limit
 (secret-service-4.0.0/src/util.rs `exec_prompt`, `receive_completed_iter.next().unwrap()`);
 here the wait ends at the operation's deadline, and a cancelled operation
 dismisses the prompt at once. Both paths send Prompt.Dismiss, which the spec
 defines as ending the prompt with Completed(dismissed = true)
 (https://specifications.freedesktop.org/secret-service/latest/prompts.html).
*>
module bleu::secrets::ss @feat(LINUX);
import std::atomic;
import std::time, bleu::deadline, bleu::error, bleu::rt::wakeup, bleu::dbus::message, bleu::dbus::match, bleu::dbus::marshal, bleu::dbus::connection, bleu::dbus::transport, bleu::secrets, bleu::service;

<* The longest one wait lasts before the cancellation flag is looked at again: 100 ms. *>
const Duration POLL_STEP = (Duration)100_000;

<* What the Completed handler recorded. *>
struct PromptWait
{
	bool completed;
	bool dismissed;
}

<*
 Show the prompt at `prompt` and wait until it completes.

 @param cancel : "The operation's cancellation flag, or null when there is no operation"
 @return? error::AUTH_REQUIRED : "The user dismissed the prompt"
 @return? error::CANCELLED : "The operation was cancelled; the prompt was dismissed"
 @return? TIMEOUT : "The prompt did not complete before the deadline; it was dismissed"
*>
fn void? run_prompt(SsBackend* b, String prompt, Atomic{bool}* cancel, String service, String account)
{
	PromptWait wait;
	match::Match rule;
	rule.init(b.allocator);
	rule.with_type(message::MessageType.SIGNAL)!;
	rule.with_interface(PROMPT_INTERFACE)!;
	rule.with_member("Completed")!;
	rule.with_path(prompt)!;
	// Subscribe before asking for the prompt, so the signal cannot be missed.
	SubscriptionId id = b.bus.subscribe(rule, &on_completed, &wait)!;
	// Whatever path leaves this function, the handler must not outlive `wait`.
	defer forget(b, id);
	emit(b, PROMPT_SHOWN, service, account);
	Message* show = call_message(tmem, prompt, PROMPT_INTERFACE, "Prompt")!;
	Writer* w = show.body_writer("s")!;
	w.append_string("")!;
	w.finish()!;
	show.flags = message::FLAG_NO_REPLY_EXPECTED;
	defer show.release();
	if (catch err = b.bus.send(show))
	{
		drop(b);
		return err~;
	}

	Deadline deadline = deadline::after(b.prompt_timeout);
	while (!wait.completed)
	{
		bool cancelled = cancel != null && cancel.load();
		if (cancelled || deadline.expired())
		{
			dismiss(b, prompt);
			emit(b, PROMPT_ENDED, service, account);
			if (cancelled) return error::CANCELLED~;
			return TIMEOUT~;
		}
		if (catch err = b.bus.process())
		{
			drop(b);
			return err~;
		}
		if (wait.completed) break;
		Duration step = deadline.remaining();
		if (step > POLL_STEP) step = POLL_STEP;
		int fd = b.bus.fd()!;
		(void)transport::wait(fd, true, b.bus.has_pending_output(), step);
	}
	emit(b, PROMPT_ENDED, service, account);
	if (wait.dismissed)
	{
		return error::raise(error::AUTH_REQUIRED, error::Domain.INTERNAL, 0, "the keyring prompt was dismissed")~;
	}
}

<*
 Ask the prompt to dismiss. Best effort: the answer is the Completed signal,
 which the waiting caller has already stopped listening for by the time it matters.
*>
fn void dismiss(SsBackend* b, String prompt)
{
	Message*? call = call_message(tmem, prompt, PROMPT_INTERFACE, "Dismiss");
	if (catch err = call) return;
	Message* message = call;
	message.flags = message::FLAG_NO_REPLY_EXPECTED;
	defer message.release();
	if (catch b.bus.send(message)) {}
}

// Stop the Completed handler. The bus may already have dropped it with the connection, so a failure here is expected and harmless.
fn void forget(SsBackend* b, SubscriptionId id)
{
	if (catch b.bus.unsubscribe(id)) {}
}

// The Completed(dismissed, result) handler. A malformed signal counts as dismissed, so the operation does not proceed.
fn void on_completed(void* context, Message* signal)
{
	PromptWait* wait = (PromptWait*)context;
	wait.completed = true;
	wait.dismissed = true;
	if (try reader = signal.reader())
	{
		if (try dismissed = reader.read_bool()) wait.dismissed = dismissed;
	}
}
