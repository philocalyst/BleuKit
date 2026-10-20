// Live checks for bleu_appearance on Linux. tests/run.sh runs this program in
// three modes against a private session bus:
//   portal  - the mock Settings portal is on the bus; GNOME keys come from gsettings
//   gsettings - no portal; the gsettings backend answers, with a wallpaper command
//   absent  - no portal and no gsettings on PATH; nothing opens
// Output: one PASS or FAIL line per check, and the exit status (0 when all pass).
module appearance_check;
import std::io, std::time, bleu::appearance, bleu::observe, bleu::operation, bleu::dbus::connection, bleu::dbus::marshal, bleu::dbus::message, bleu::error, bleu::stream;

const String PORTAL_NAME  = "org.freedesktop.portal.Desktop";
const String CONTROL_PATH = "/org/bleu/PortalMock";
const String CONTROL_IF   = "org.bleu.PortalMock";
const String NAMESPACE    = "org.freedesktop.appearance";
const Duration WAIT       = (Duration)5_000_000;

int failures = 0;

fn void check(bool ok, String what)
{
	if (ok)
	{
		io::printfn("PASS %s", what);
		return;
	}
	io::printfn("FAIL %s", what);
	failures++;
}

fn bool near(float a, float b) => a - b < 0.01f && b - a < 0.01f;

// Tell the mock portal to change one uint setting, which makes it emit SettingChanged.
fn void set_portal_uint(Connection* ctl, String key, uint value)
{
	Message* call = message::method_call(mem, PORTAL_NAME, CONTROL_PATH, CONTROL_IF, "Set")!!;
	defer call.release();
	marshal::Writer* w = call.body_writer("ssv")!!;
	w.append_string(NAMESPACE)!!;
	w.append_string(key)!!;
	w.begin_variant("u")!!;
	w.append_u32(value)!!;
	w.end_variant()!!;
	Message* reply = ctl.call(call, time::ms(3000))!!;
	reply.release();
}

// Wait for a state newer than `seen`; the caller releases it.
fn Snapshot{State}* next_state(Appearance* app, ulong seen)
{
	return app.wait_after(seen, WAIT)!!;
}

fn int portal_mode(Connection* ctl)
{
	Appearance* app = appearance::open(mem, { .poll = time::ms(200) })!!;
	defer app.close();
	check(app.backend_name() == "portal", "AUTO picks the portal backend when the portal is on the bus");
	Snapshot{State}* first = next_state(app, 0);
	defer first.release();
	State* s = &first.value;
	check(s.color_scheme == DARK, "portal colour scheme is dark (variant unwrapped)");
	check(
		s.accent.has_value && near((float)s.accent.value.red, 0.2f) && near((float)s.accent.value.blue, 0.8f),
		"accent (ddd) read"
	);
	check(s.contrast == NORMAL, "contrast read as normal");
	check(s.reduced_motion, "reduced motion read from the portal");
	check(s.font_name == "Test Sans 12", "font from gsettings");
	check(s.text_scale.has_value && near((float)s.text_scale.value, 1.25f), "text scale from gsettings");
	check(s.clock_format == H24, "clock format from gsettings");
	check(
		s.wallpapers.len == 1 && s.wallpapers[0].path == "/usr/share/backgrounds/test-light.png",
		"picture-uri from gsettings"
	);
	check(app.capability(COLOR_SCHEME_SET).ok(), "scheme can be set through GNOME");
	check(!app.capability(REDUCED_TRANSPARENCY).ok(), "reduced transparency reported unsupported");

	bleu::stream::Reader{Event}* events = app.subscribe()!!;
	defer events.release();

	set_portal_uint(ctl, "color-scheme", 2);
	Snapshot{State}* light = next_state(app, first.generation);
	defer light.release();
	check(light.value.color_scheme == LIGHT, "a SettingChanged signal updates the scheme (Read path)");
	Packet{Event}* scheme_event = events.next(time::ms(3000))!!;
	defer scheme_event.release();
	check(scheme_event.value.kind == COLOR_SCHEME, "a scheme change emits a COLOR_SCHEME event");

	set_portal_uint(ctl, "contrast", 1);
	Snapshot{State}* high = next_state(app, light.generation);
	defer high.release();
	check(high.value.contrast == HIGH, "a contrast change is read and published");
	Packet{Event}* access_event = events.next(time::ms(3000))!!;
	defer access_event.release();
	check(access_event.value.kind == ACCESSIBILITY, "a contrast change emits an ACCESSIBILITY event");

	Operation{bool}* scheme_op = app.set_color_scheme(DARK)!!;
	defer scheme_op.release();
	check(scheme_op.wait(WAIT)!!, "set_color_scheme(DARK) succeeds through gsettings");

	String new_path               = "/usr/share/backgrounds/bleu-new.png";
	Operation{bool}* wallpaper_op = app.set_wallpaper(new_path)!!;
	defer wallpaper_op.release();
	check(wallpaper_op.wait(WAIT)!!, "set_wallpaper succeeds through gsettings");
	Snapshot{State}* moved = next_state(app, high.generation);
	defer moved.release();
	check(
		moved.value.wallpapers.len == 1 && moved.value.wallpapers[0].path == new_path,
		"the new picture is published"
	);

	check(@catch(app.set_wallpaper("relative.png")) == error::INVALID_ARGUMENT, "a relative wallpaper path is refused");
	return failures;
}

fn int gsettings_mode(String marker)
{
	String[4] command = { "/bin/sh", "-c", "echo '{path}' > \"$0\"", marker };
	Appearance* app   = appearance::open(mem, { .poll = time::ms(200), .wallpaper_command = command[..] })!!;
	defer app.close();
	check(app.backend_name() == "gsettings", "AUTO falls back to gsettings when no portal answers");
	Snapshot{State}* first = next_state(app, 0);
	defer first.release();
	check(first.value.color_scheme == LIGHT, "gsettings colour scheme is light");
	check(first.value.reduced_motion == false, "gsettings reduced motion from enable-animations");
	check(!app.capability(ACCENT).ok(), "accent unsupported in the gsettings backend");
	check(first.value.font_name == "Test Sans 12", "gsettings font");

	Operation{bool}* scheme_op = app.set_color_scheme(DARK)!!;
	defer scheme_op.release();
	check(scheme_op.wait(WAIT)!!, "set_color_scheme(DARK) succeeds");
	Snapshot{State}* dark = next_state(app, first.generation);
	defer dark.release();
	check(dark.value.color_scheme == DARK, "the new scheme is published");

	Operation{bool}* wallpaper_op = app.set_wallpaper("/tmp/bleu-wallpaper.png")!!;
	defer wallpaper_op.release();
	check(wallpaper_op.wait(WAIT)!!, "set_wallpaper runs the configured command");
	return failures;
}

fn int absent_mode()
{
	check(@catch(appearance::open(mem)) == error::UNAVAILABLE, "AUTO opens nothing with no portal and no gsettings");
	check(
		@catch(appearance::open(mem, { .backend = PORTAL })) == error::UNAVAILABLE,
		"a named backend that does not work is UNAVAILABLE"
	);
	check(
		@catch(appearance::open(mem, { .backend = WIN32 })) == error::UNSUPPORTED,
		"a backend of another OS is UNSUPPORTED"
	);
	return failures;
}

fn int main(String[] args)
{
	if (args.len < 2)
	{
		io::printn("usage: appearance_check portal|gsettings|absent [marker-file]");
		return 2;
	}
	String mode = args[1];
	Connection ctl;
	ctl.init(mem);
	defer ctl.free();
	if (mode == "absent") return absent_mode();
	if (mode == "gsettings") return gsettings_mode(args.len > 2 ? args[2] : "/dev/null");
	ctl.open_session()!!;
	return portal_mode(&ctl);
}