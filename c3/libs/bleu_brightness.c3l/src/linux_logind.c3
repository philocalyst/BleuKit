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

const String SERVICE = "org.freedesktop.login1";
const String SESSION_PATH = "/org/freedesktop/login1/session/auto";
const String SESSION_INTERFACE = "org.freedesktop.login1.Session";
const String SUBSYSTEM_BACKLIGHT = "backlight";
const String SUBSYSTEM_LEDS = "leds";

<* How long a SetBrightness may take: logind waits for the write, which can be slow on I2C. *>
const Duration CALL_TIMEOUT = (Duration)5_000_000;

<*
 Ask logind to set `name` of `subsystem` to `raw`, and wait until it has written it.

 @param bus : "An open system (or test) bus, used on the worker thread only"
 @param subsystem : "`SUBSYSTEM_BACKLIGHT` or `SUBSYSTEM_LEDS`"
 @return? error::UNAVAILABLE : "logind is not on the bus"
 @return? error::PERMISSION_DENIED, error::AUTH_REQUIRED : "logind refused the call"
 @return? NOT_FOUND : "This logind has no SetBrightness method (systemd before 2.x)"
 @return? error::DISCONNECTED, error::BACKEND_FAILURE : "The bus failed during the call"
*>
fn void? set_brightness(Connection* bus, String subsystem, String name, uint raw)
{
	@pool()
	{
		Proxy session = proxy::for_object(bus, SERVICE, SESSION_PATH, SESSION_INTERFACE)!;
		Message* call = session.new_call(tmem, "SetBrightness")!;
		Writer* body = call.body_writer("ssu")!;
		body.append_string(subsystem)!;
		body.append_string(name)!;
		body.append_u32(raw)!;
		body.finish()!;
		Message* reply = bus.call(call, CALL_TIMEOUT)!;
		reply.release();
	};
}
