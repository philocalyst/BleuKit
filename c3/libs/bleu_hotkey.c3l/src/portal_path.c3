<*
 The object paths of the portal protocol, as pure functions.

 Every portal call answers with a Request object, and the answer arrives as the Request's
 `Response` signal. Since xdg-desktop-portal 0.9 the Request path is computable by the caller, so it
 can subscribe to `Response` before it makes the call, which avoids a race. The rule
 (org.freedesktop.portal.Request, xdg-desktop-portal data/org.freedesktop.portal.Request.xml):

 /org/freedesktop/portal/desktop/request/SENDER/TOKEN

 where SENDER is the caller's unique bus name with the leading ':' removed and every '.' replaced by
 '_', and TOKEN is the `handle_token` the caller passed. Sessions follow the same rule under
 `.../session/` with `session_handle_token` (org.freedesktop.portal.Session.xml).
*>
module bleu::hotkey::portal_path;
import bleu::error;

const String PORTAL_ROOT = "/org/freedesktop/portal/desktop";

<*
 The SENDER element of a request or session path for a unique bus name: ":1.42" becomes "1_42".

 @param unique_name : "A unique connection name, which starts with ':'"
 @param allocator : "Owns the returned text"
 @return? error::INVALID_ARGUMENT : "The name is not a unique name"
*>
fn String? sender_element(String unique_name, Allocator allocator)
{
	if (unique_name.len < 2 || unique_name[0] != ':') return error::INVALID_ARGUMENT~;
	String element = unique_name[1:unique_name.len - 1].copy(allocator);
	for (sz i = 0; i < element.len; i++)
	{
		if (element[i] == '.') element[i] = '_';
	}
	return element;
}

<*
 Whether `token` may be the last element of an object path: a non-empty run of ASCII letters,
 digits and underscores (the D-Bus object path grammar).
*>
fn bool is_token(String token)
{
	if (token.len == 0) return false;
	foreach (c : token)
	{
		bool word = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
		if (!word) return false;
	}
	return true;
}

<*
 The Request object path a call with `handle_token = token` will answer on.

 @param unique_name : "The caller's unique bus name, for example \":1.42\""
 @param token : "The handle_token passed in the call's options"
 @param allocator : "Owns the returned path"
 @return? error::INVALID_ARGUMENT : "The name is not unique, or the token is not a path element"
*>
fn String? request_path(String unique_name, String token, Allocator allocator)
{
	return object_path("request", unique_name, token, allocator);
}

<*
 The Session object path a session created with `session_handle_token = token` will have.

 @param unique_name : "The caller's unique bus name"
 @param token : "The session_handle_token passed to CreateSession"
 @param allocator : "Owns the returned path"
 @return? error::INVALID_ARGUMENT : "The name is not unique, or the token is not a path element"
*>
fn String? session_path(String unique_name, String token, Allocator allocator)
{
	return object_path("session", unique_name, token, allocator);
}

// Shared body of `request_path` and `session_path`: `kind` is "request" or "session".
fn String? object_path(String kind, String unique_name, String token, Allocator allocator) @private
{
	if (!is_token(token)) return error::INVALID_ARGUMENT~;
	@pool()
	{
		String element = sender_element(unique_name, tmem)!;
		return string::tformat("%s/%s/%s/%s", PORTAL_ROOT, kind, element, token).copy(allocator);
	};
}

<*
 A handle token that is unique for this caller: "bleu_hotkey_<counter>". The caller's unique name
 already makes the path unique across callers, so a per-connection counter is enough.

 @param counter : "A number the caller increments for each call"
 @param allocator : "Owns the returned token"
*>
fn String token(uint counter, Allocator allocator)
{
	@pool()
	{
		return string::tformat("bleu_hotkey_%d", (int)counter).copy(allocator);
	};
}