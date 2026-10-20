<* The `appearance` entry of the registry: open adapter, commands and `Spec`. *>
module bleu::registry::svc_appearance;
import bleu::appearance, bleu::registry, bleu::registry::live, bleu::json, bleu::operation, bleu::registry::tap;

<* Open the appearance service with its default backend. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	appearance::Appearance* service = appearance::open(allocator)!;
	return (void*)service;
}

<* `appearance.set_color_scheme {scheme}`: dark, light or no preference. *>
fn void? set_color_scheme(registry::Request* request)
{
	appearance::Appearance* service = (appearance::Appearance*)request.handle;
	appearance::ColorScheme scheme = registry::parse_enum{appearance::ColorScheme}(request.params.string("scheme")!)!;
	Operation{bool}* operation = service.set_color_scheme(scheme)!;
	defer operation.release();
	registry::await{bool}(operation, request.timeout)!;
	return registry::write_ok(request.out);
}

<* `appearance.set_wallpaper {path}`: set the wallpaper image. *>
fn void? set_wallpaper(registry::Request* request)
{
	appearance::Appearance* service = (appearance::Appearance*)request.handle;
	Operation{bool}* operation = service.set_wallpaper(request.params.string("path")!)!;
	defer operation.release();
	registry::await{bool}(operation, request.timeout)!;
	return registry::write_ok(request.out);
}

const registry::Command[2] COMMANDS = {
	{ .name = "appearance.set_color_scheme", .summary = "Dark, light or no preference: {scheme}.", .run = &set_color_scheme },
	{ .name = "appearance.set_wallpaper", .summary = "Set the wallpaper: {path}.", .run = &set_wallpaper },
};

const registry::Spec APPEARANCE = {
	.name = "appearance",
	.summary = "Colour scheme, accent, fonts, wallpaper (portal, gsettings, AppKit, Win32)",
	.open = &open,
	.close = &live::close{appearance::Appearance, appearance::State, appearance::Cap},
	.state = &live::state{appearance::Appearance, appearance::State, appearance::Cap},
	.state_after = &live::state_after{appearance::Appearance, appearance::State, appearance::Cap},
	.capabilities = &live::capabilities{appearance::Appearance, appearance::State, appearance::Cap},
	.backend = &live::backend{appearance::Appearance, appearance::State, appearance::Cap},
	.watch = &tap::watch{appearance::Appearance, appearance::State},
	.commands = COMMANDS[..],
};
