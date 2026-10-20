<*
 The decisions the centre makes about a notification, as pure functions: how long
 it stays, which id it gets, whether do-not-disturb holds it back.
*>
module bleu::notify::rules;
import std::collections::maybe, std::time, bleu::notify;

<*
 How long a notification stays on screen, from the urgency and the sender's
 timeout (`expire_ms`: -1 server default, 0 never, more than 0 milliseconds).
 Critical notifications never expire on their own, whatever was asked.
*>
fn Maybe{Duration} timeout_for(notify::Urgency urgency, int expire_ms, notify::Policy* policy)
{
	if (urgency == notify::Urgency.CRITICAL || expire_ms == 0) return { };
	if (expire_ms > 0) return maybe::value(time::ms(expire_ms));
	Duration default_timeout = urgency == notify::Urgency.LOW ? policy.low_timeout : policy.normal_timeout;
	if (default_timeout <= time::DURATION_ZERO) return { };
	return maybe::value(default_timeout);
}

<* The id after `last`: never zero, and it wraps past the largest uint. *>
fn notify::NoteId next_id(notify::NoteId last)
{
	uint next = last + 1;
	return next == 0 ? 1 : next;
}

<* Whether do-not-disturb keeps this notification off the screen. Critical notifications always show. *>
fn bool held_by_dnd(bool do_not_disturb, notify::Urgency urgency) @inline
{
	return do_not_disturb && urgency != notify::Urgency.CRITICAL;
}
