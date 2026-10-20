<*
 Pure conversions of what platforms report, into the vocabulary of `model.c3`. No I/O, so
 every host runs the tests in `common_test.c3`.
*>
module bleu::session;

<*
 The session type named by logind (`Type` of org.freedesktop.login1.Session: "tty", "x11",
 "wayland", "mir", "unspecified"). UNKNOWN for any other text.
*>
fn SessionType session_type_of(String text)
{
	if (text == "unspecified") return UNSPECIFIED;
	if (text == "tty") return TTY;
	if (text == "x11") return X11;
	if (text == "wayland") return WAYLAND;
	if (text == "mir") return MIR;
	return UNKNOWN;
}

<* The first wait before a backend looks for its session again: one second, in microseconds. *>
const long RETRY_FIRST_MICROS = 1_000_000;
<* The longest wait between two looks for a session: 30 seconds, in microseconds. *>
const long RETRY_LIMIT_MICROS = 30_000_000;

<*
 How long to wait before the next look for a session that was not found (or could not be read), after
 `failures` looks that found none: one second, then doubling, up to 30 seconds.

 @param failures : "Looks that found no session since the last connection; 0 before the first"
*>
fn Duration retry_delay(usz failures)
{
	long micros = RETRY_FIRST_MICROS;
	for (usz i = 1; i < failures && micros < RETRY_LIMIT_MICROS; i++) micros *= 2;
	return (Duration)min(micros, RETRY_LIMIT_MICROS);
}
