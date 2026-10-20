<*
 The logind route for backlights and LEDs: `org.freedesktop.login1.Session`
 `SetBrightness(subsystem, name, brightness)` on the caller's own session. It
 needs no group membership: logind does the write as root, for the session that
 is in the foreground on its seat.

 Sources: systemd `org.freedesktop.login1(5)` ("SetBrightness()"), and
 src/login/logind-session-dbus.c (`SD_BUS_ARGS("s", subsystem, "s", name, "u", brightness)`
 at line 1085) with its access rules in the same file, lines 671-720: the call is
 refused unless the session is on a seat and in the foreground, and the subsystem
 is `backlight` or `leds`. There is no polkit check.
 The `session/auto` object path names the caller's own session.
*>
module bleu::brightness::logind @feat(LINUX);
import bleu::dbus::connection, bleu::dbus::message, bleu::dbus::proxy, bleu::dbus::marshal, bleu::error, std::time;

<*
 How long a SetBrightness may take. logind writes a sysfs file, so a longer wait only stalls
 the worker: a call that has not answered by then is treated as a refusal.
*>
const Duration CALL_TIMEOUT = (Duration)1_000_000;

<*
 How long a route stays off after logind refused a call, or the bus failed to open, before it
 is tried again. Measured on the backend's own clock (time since start).
*>
const Duration RETRY_INTERVAL = (Duration)30_000_000;

<*
 Whether logind may be asked, for one subsystem or for the bus. A refusal switches the route off
 for `RETRY_INTERVAL`: a session logind refuses (for example one not in the foreground) is not
 asked again on every write, and does not stall the worker each time.
*>
struct Route
{
	bool refused;
	Duration refused_at;
}

<* Whether the route may be used at `now`: it was never refused, or its retry interval has passed. *>
fn bool Route.usable(&self, Duration now) @inline => !self.refused || now - self.refused_at >= RETRY_INTERVAL;

<* Switch the route off from `now` for `RETRY_INTERVAL`. *>
fn void Route.refuse(&self, Duration now)
{
	self.refused = true;
	self.refused_at = now;
}

<* The last call on the route succeeded: it is on again. *>
fn void Route.accept(&self)
{
	self.refused = false;
}

<* A sentence for a failed logind route, for the detail of a write that then fell back to the file. *>
fn String refusal_text(fault failure)
{
	if (failure == error::PERMISSION_DENIED || failure == error::AUTH_REQUIRED) return "refused the call";
	if (failure == TIMEOUT) return "did not answer in time";
	return "is not reachable";
}

const String SERVICE             = "org.freedesktop.login1";
const String SESSION_PATH        = "/org/freedesktop/login1/session/auto";
const String SESSION_INTERFACE   = "org.freedesktop.login1.Session";
const String SUBSYSTEM_BACKLIGHT = "backlight";
const String SUBSYSTEM_LEDS      = "leds";


<*
 Ask logind to set `name` of `subsystem` to `raw`, and wait until it has written it.

 @param bus : "An open system (or test) bus, used on the worker thread only"
 @param subsystem : "`SUBSYSTEM_BACKLIGHT` or `SUBSYSTEM_LEDS`"
 @return? error::UNAVAILABLE : "logind is not on the bus"
 @return? error::PERMISSION_DENIED, error::AUTH_REQUIRED : "logind refused the call"
 @return? NOT_FOUND : "This logind has no SetBrightness method (systemd before 2.x)"
 @return? TIMEOUT : "logind did not answer within `CALL_TIMEOUT`"
 @return? error::DISCONNECTED, error::BACKEND_FAILURE : "The bus failed during the call"
*>
fn void? set_brightness(Connection* bus, String subsystem, String name, uint raw)
{
	@pool()
	{
		Proxy session = proxy::for_object(bus, SERVICE, SESSION_PATH, SESSION_INTERFACE)!;
		Message* call = session.new_call(tmem, "SetBrightness")!;
		Writer* body  = call.body_writer("ssu")!;
		body.append_string(subsystem)!;
		body.append_string(name)!;
		body.append_u32(raw)!;
		body.finish()!;
		Message* reply = bus.call(call, CALL_TIMEOUT)!;
		reply.release();
	};
}