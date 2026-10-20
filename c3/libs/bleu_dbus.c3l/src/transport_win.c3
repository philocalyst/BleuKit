<*
 Windows side of the transport. D-Bus is not provided on Windows by Bleu: the
 names below exist so that the rest of the library type-checks there, and every
 operation that would touch a socket raises `UNSUPPORTED`. The POSIX versions in
 `transport_posix.c3` define the same names with the same signatures.
*>
module bleu::dbus::transport @feat(!POSIX);
import bleu::error, std::time, std::collections::list;

<*
 Not available on Windows.

 @return? error::UNSUPPORTED : "D-Bus transports are not implemented on Windows"
*>
fn int? connect_unix(String path, bool abstract)
{
	return error::UNSUPPORTED~;
}

<*
 Most descriptors one message may carry. Same value as the POSIX file: the
 kernel limit SCM_MAX_FD on Linux, used on every platform.
*>
const MAX_DESCRIPTORS = 253;

<* Nothing to close: no descriptor can exist on this platform. *>
fn void close_fd(int fd)
{
}

<*
 Not available on Windows.

 @return? error::UNSUPPORTED : "D-Bus transports are not implemented on Windows"
*>
fn usz? send_some(int fd, String bytes, usz offset, int[] descriptors)
{
	return error::UNSUPPORTED~;
}

<*
 Not available on Windows.

 @return? error::UNSUPPORTED : "D-Bus transports are not implemented on Windows"
*>
fn usz? recv_some(int fd, char[] buffer, usz offset, List{int}* descriptors)
{
	return error::UNSUPPORTED~;
}

<* No descriptor can be waited on here, so nothing ever becomes ready. *>
fn bool wait(int fd, bool readable, bool writable, Duration timeout) => false;

<*
 Not available on Windows.

 @return? error::UNSUPPORTED : "D-Bus transports are not implemented on Windows"
*>
fn uint? current_uid()
{
	return error::UNSUPPORTED~;
}