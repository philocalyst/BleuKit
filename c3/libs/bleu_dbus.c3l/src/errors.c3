<*
 D-Bus error names, as the Bleu excuse vocabulary.

 A failed call carries a D-Bus error name such as
 `org.freedesktop.DBus.Error.ServiceUnknown`. Shells need the stable classes of
 `bleu::error` (the same ones every service uses), so this module maps each
 name onto one, and keeps the D-Bus name and message in `error::last()` for
 diagnostics.

 Sources: D-Bus specification, "Standard Interfaces" and the errors defined by
 the bus daemon (org.freedesktop.DBus.Error.*); polkit's
 org.freedesktop.PolicyKit1.Error.NotAuthorized for authorization refusals.
*>
module bleu::dbus::errors;
import bleu::error, bleu::dbus::message;

<* Suffix of the polkit authorization refusal, whose namespace is per-service. *>
const POLKIT_NOT_AUTHORIZED_SUFFIX = ".NotAuthorized";

<*
 The excuse that a D-Bus error name stands for.

 @param name : "The ERROR_NAME of the reply"
*>
fn fault for_name(String name)
{
	if (name == "org.freedesktop.DBus.Error.ServiceUnknown"
		|| name == "org.freedesktop.DBus.Error.NameHasNoOwner") return error::UNAVAILABLE;
	if (name == "org.freedesktop.DBus.Error.AccessDenied"
		|| name == "org.freedesktop.DBus.Error.AuthFailed") return error::PERMISSION_DENIED;
	if (name == "org.freedesktop.DBus.Error.InteractiveAuthorizationRequired") return error::AUTH_REQUIRED;
	if (name == "org.freedesktop.DBus.Error.UnknownMethod" || name == "org.freedesktop.DBus.Error.UnknownObject"
		|| name == "org.freedesktop.DBus.Error.UnknownInterface"
		|| name == "org.freedesktop.DBus.Error.UnknownProperty") return NOT_FOUND;
	if (name == "org.freedesktop.DBus.Error.InvalidArgs") return error::INVALID_ARGUMENT;
	if (name == "org.freedesktop.DBus.Error.NoReply" || name == "org.freedesktop.DBus.Error.Timeout") return TIMEOUT;
	if (name == "org.freedesktop.DBus.Error.Disconnected") return error::DISCONNECTED;
	if (name.ends_with(POLKIT_NOT_AUTHORIZED_SUFFIX)) return error::AUTH_REQUIRED;
	return error::BACKEND_FAILURE;
}

<*
 The fault for an ERROR reply. The D-Bus error name and the reply's text are
 recorded with `error::raise` (domain DBUS), so `error::last()` shows them.

 @param reply : "A message of type ERROR"
 @return "The fault to return to the caller, with the details recorded"
*>
fn fault from_reply(Message* reply)
{
	String text = reply.error_text() ?? "";
	return error::raise(for_name(reply.error_name), error::Domain.DBUS, 0, "%s: %s", reply.error_name, text);
}