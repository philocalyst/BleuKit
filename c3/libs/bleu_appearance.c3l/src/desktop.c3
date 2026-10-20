<*
 Setting the wallpaper on Linux. A configured command (for a compositor's own
 tool, such as `swww img {path}`) is used when there is one; otherwise GNOME's
 gsettings keys are written. Both run as argv, never through a shell.
*>
module bleu::appearance::desktop @feat(LINUX);
import std::os::process, bleu::appearance::convert, bleu::appearance::gnome, bleu::error;

<*
 Set the wallpaper to `path`.

 @param command : "argv template from Options.wallpaper_command; empty for GNOME's keys"
 @return? error::BACKEND_FAILURE : "The wallpaper command or gsettings failed"
*>
fn void? set_wallpaper(String[] command, String path)
{
	if (command.len == 0) return gnome::set_wallpaper(path);
	@pool()
	{
		String[] argv = convert::substitute(tmem, command, path);
		int status    = process::run(argv, process::SpawnOptions.INHERIT_ENV)!;
		if (status != 0)
		{
			return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, status, "wallpaper command exited with %d", status)~;
		}
	};
}
