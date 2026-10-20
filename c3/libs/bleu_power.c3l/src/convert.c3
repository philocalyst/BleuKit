<*
 Conversions between the words the OS daemons use and Bleu's enums. Pure (no
 I/O), so every mechanism shares one reading of the same strings and the
 conversions can be tested on any machine.

 Sources: power-profiles-daemon `src/power-profiles-daemon.c` (profile names,
 `PerformanceDegraded` values) and systemd `docs/INHIBITOR_LOCKS.md` and the
 login1 manual page (the `Can*` answers, section "Methods").
*>
module bleu::power::convert;
import bleu::power, bleu::availability, bleu::error;

<* The daemon's name for a profile. `UNKNOWN` has none. *>
fn String? profile_name(Profile profile)
{
	switch (profile)
	{
		case POWER_SAVER: return "power-saver";
		case BALANCED: return "balanced";
		case PERFORMANCE: return "performance";
		case UNKNOWN: return error::INVALID_ARGUMENT~;
	}
}

<*
 The profile for a daemon name.

 @return? NOT_FOUND : "The name is not one of the three profiles"
*>
fn Profile? profile_from_name(String name)
{
	switch (name)
	{
		case "power-saver": return POWER_SAVER;
		case "balanced": return BALANCED;
		case "performance": return PERFORMANCE;
		default: return NOT_FOUND~;
	}
}

<*
 The reason a profile is held back, from `PerformanceDegraded`. An empty
 string means not degraded; a reason this library does not name is `OTHER`.
*>
fn Degraded degraded_from_text(String text)
{
	switch (text)
	{
		case "": return NONE;
		case "lap-detected": return LAP_DETECTED;
		case "high-operating-temperature": return HIGH_TEMPERATURE;
		default: return OTHER;
	}
}

<*
 The availability that a logind `Can*` answer stands for. Each answer is
 documented in the login1 manual page; the reasons are chosen so that
 `ok()` is true exactly when the action can proceed without the user's help.

 @param answer : "The string the method returned"
 @return? error::PROTOCOL : "The answer is not one the manual page defines"
*>
fn Availability? availability_from_can(String answer)
{
	switch (answer)
	{
		case "yes":
			return availability::YES;
		case "challenge":
			return availability::no(availability::Reason.PERMISSION_NEEDED, "the system will ask the user to authorise it");
		case "na":
			return availability::no(availability::Reason.HARDWARE_ABSENT, "the hardware, kernel or drivers do not support it");
		case "no":
			return availability::no(availability::Reason.DISABLED_BY_POLICY, "the system configuration does not allow it");
		case "inhibited":
			return { .reason = availability::Reason.DEGRADED, .note = "another program holds an inhibitor lock; it may refuse" };
		case "inhibitor-blocked":
			return availability::no(availability::Reason.DISABLED_BY_POLICY, "another program's inhibitor lock blocks it now");
		case "challenge-inhibitor-blocked":
			return availability::no(availability::Reason.PERMISSION_NEEDED, "authorisation is needed, and an inhibitor lock blocks it now");
		default:
			return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "unknown Can* answer '%s'", answer)~;
	}
}
