<*
 Non-POSIX half of `bleu::wl::display`. Wayland is a Unix-socket protocol; on other
 systems every operation here raises UNSUPPORTED, so the rest of the library still
 type-checks and `Client.connect` fails in a documented way.
*>
module bleu::wl::display @feat(!POSIX);
import bleu::rt, bleu::error, bleu::wl::wire;

<* Not available on this system: Wayland needs Unix sockets. *>
fn rt::Native? native_dup(
	rt::Native fd
) => error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "Wayland needs Unix sockets")~;

<* Nothing was ever opened here, so there is nothing to close. *>
fn void native_close(rt::Native fd)
{
}

<* Not available on this system. *>
fn void? native_send(
	rt::Native fd,
	char[] bytes,
	rt::Native[] fds,
	usz* accepted
) => error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "Wayland needs Unix sockets")~;

<* Not available on this system. *>
fn void? native_recv(
	rt::Native fd,
	char[] buffer,
	rt::Native[] fds,
	Received* out
) => error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "Wayland needs Unix sockets")~;

<* Not available on this system. *>
fn void? native_set_nonblocking(
	rt::Native fd,
	bool non_blocking
) => error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "Wayland needs Unix sockets")~;

<* Not available on this system. *>
fn rt::Native? native_connect(
	String path
) => error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "Wayland needs Unix sockets")~;