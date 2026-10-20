<*
 Connecting on systems without Unix sockets: every connect raises UNSUPPORTED, and
 `Client.init` (in `client.c3`) still works for a descriptor the caller provides.
*>
module bleu::wl @feat(!POSIX);
import bleu::error, bleu::rt;

<* Not available on this system: the compositor socket cannot be reached. *>
fn void? Client.connect(&self, Allocator allocator, String path) => error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "Wayland needs Unix sockets")~;

<* Not available on this system: the compositor socket cannot be reached. *>
fn void? Client.connect_env(&self, Allocator allocator) => error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "Wayland needs Unix sockets")~;
