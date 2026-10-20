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
