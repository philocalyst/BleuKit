<* The `display` entry of the registry: open adapter, commands and `Spec`. *>
module bleu::registry::svc_display;
import bleu::display, bleu::registry, bleu::registry::live, bleu::json;

<* Open the display service. Its root points at a fake tree for EDID lookup in tests. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	display::Options opened = { .root = options.root };
	display::Display* service = display::open(allocator, opened)!;
	return (void*)service;
}

<* `display.refresh`: re-read the outputs now. *>
fn void? refresh(registry::Request* request)
{
	display::Display* service = (display::Display*)request.handle;
	service.refresh()!;
	return registry::write_ok(request.out);
}

const registry::Command[1] COMMANDS = {
	{ .name = "display.refresh", .summary = "Re-read the outputs now.", .run = &refresh },
};

const registry::Spec DISPLAY = {
	.name = "display",
	.summary = "Outputs, modes and layout (wlr-output-management, DRM, CoreGraphics, Win32)",
	.open = &open,
	.close = &live::close{display::Display, display::State, display::Cap},
	.state = &live::state{display::Display, display::State, display::Cap},
	.state_after = &live::state_after{display::Display, display::State, display::Cap},
	.capabilities = &live::capabilities{display::Display, display::State, display::Cap},
	.backend = &live::backend{display::Display, display::State, display::Cap},
	.watch = &live::watch{display::Display, display::State, display::Cap},
	.commands = COMMANDS[..],
};
