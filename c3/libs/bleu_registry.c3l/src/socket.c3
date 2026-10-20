<*
 Where the daemon and its client meet by default: `$XDG_RUNTIME_DIR/bleud.sock`.
 Both `bleud` and `bleuctl` use it unless they are given `--socket`.
*>
module bleu::registry;
import std::os::env, std::core::string, bleu::error;

<* The socket file name inside `$XDG_RUNTIME_DIR`. *>
const String SOCKET_NAME = "bleud.sock";

<*
 The default socket path, from `XDG_RUNTIME_DIR`.

 @return? error::UNAVAILABLE : "XDG_RUNTIME_DIR is not set, so there is no private place for the socket"
*>
fn String? default_socket_path(Allocator allocator)
{
	String runtime = env::tget_var("XDG_RUNTIME_DIR") ?? "";
	if (runtime.len == 0) return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "XDG_RUNTIME_DIR is not set; pass --socket")~;
	return string::tformat("%s/%s", runtime, SOCKET_NAME).copy(allocator);
}
