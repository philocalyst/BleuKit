<*
 Honest answers to "can this service do that here?".

 A service never pretends. Each operation it offers is a `Capability`, and each
 capability is either available or comes with the reason it is not, so a shell
 can grey out a button and say why instead of failing on click.
*>
module bleu::availability;
import bleu::error;

enum Reason : char
{
	AVAILABLE,
	UNSUPPORTED_OS,      // This operating system has no way to do it
	UNSUPPORTED_BACKEND, // The active backend cannot (e.g. iwd lacks hotspot)
	BACKEND_MISSING,     // A needed daemon/library/framework is not installed
	BACKEND_STOPPED,     // Installed but not running
	HARDWARE_ABSENT,     // No device exposes it
	PERMISSION_NEEDED,   // The user must grant it (TCC, polkit, group membership)
	DISABLED_BY_POLICY,  // The platform or administrator turned it off
	DEGRADED,            // Works, with caveats described in `note`
}

<*
 One capability's availability. `note` is a static, human-readable sentence;
 it is never freed.
*>
struct Availability
{
	Reason reason;
	String note;
}

const Availability YES = { AVAILABLE, "" };

fn bool Availability.ok(self) @inline => self.reason == AVAILABLE || self.reason == DEGRADED;

fn Availability no(Reason reason, String note = "") @inline => { reason, note };

<*
 Convert to the fault a refused operation should raise.
*>
fn fault Availability.refusal(self)
{
	switch (self.reason)
	{
		case AVAILABLE:
		case DEGRADED: unreachable("an available capability has no fault");
		case UNSUPPORTED_OS:
		case UNSUPPORTED_BACKEND: return error::UNSUPPORTED;
		case PERMISSION_NEEDED: return error::PERMISSION_DENIED;
		case BACKEND_MISSING:
		case BACKEND_STOPPED:
		case HARDWARE_ABSENT:
		case DISABLED_BY_POLICY: return error::UNAVAILABLE;
	}
}

<*
 Describes one concrete way of providing a service. Backends are probed in
 priority order; the first whose `probe` succeeds wins unless the caller
 forces one by name.
*>
struct BackendInfo
{
	String name; // stable identifier: "networkmanager", "corewlan", "wlanapi"
	String description; // one line for logs and diagnostics
	int priority; // higher is tried first
}