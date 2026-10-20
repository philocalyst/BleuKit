<* The `clipboard` entry of the registry: open adapter, commands and `Spec`. *>
module bleu::registry::svc_clipboard;
import bleu::clipboard, bleu::registry, bleu::registry::live, bleu::json, bleu::operation, bleu::registry::tap;

<* Open the clipboard service with its default backend. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	clipboard::Options opened     = { };
	clipboard::Clipboard* service = clipboard::open(allocator, opened)!;
	return (void*)service;
}

<* `clipboard.set_text {slot?, text}`: place text on the clipboard (or the primary selection). *>
fn void? set_text(registry::Request* request)
{
	clipboard::Clipboard* service = (clipboard::Clipboard*)request.handle;
	String slot                   = registry::string_or(request.params, "slot", "clipboard")!;
	clipboard::Slot target        = registry::parse_enum{clipboard::Slot}(slot)!;
	String text                   = request.params.string("text")!;
	Operation{ulong}* operation   = service.set_text(target, text)!;
	defer operation.release();
	ulong id = registry::await{ulong}(operation, request.timeout)!;
	return registry::write_value(request.out, "id", id);
}

<* `clipboard.fetch {id, mime}`: the bytes of one history entry in one MIME type, as base64. *>
fn void? fetch(registry::Request* request)
{
	clipboard::Clipboard* service          = (clipboard::Clipboard*)request.handle;
	clipboard::Entry entry                 = { .id = (ulong)request.params.integer("id")! };
	String mime                            = request.params.string("mime")!;
	Operation{clipboard::Bytes}* operation = service.fetch(entry, mime)!;
	defer operation.release();
	clipboard::Bytes bytes = registry::await{clipboard::Bytes}(operation, request.timeout)!;
	return registry::write_value(request.out, "bytes", bytes);
}

const registry::Command[2] COMMANDS = {
	{ .name = "clipboard.set_text", .summary = "Copy text: {slot?, text}.", .run = &set_text },
	{ .name = "clipboard.fetch", .summary = "Read one history entry as base64: {id, mime}.", .run = &fetch },
};

const registry::Spec CLIPBOARD = {
	.name = "clipboard",
	.summary = "Clipboard and primary selection with history (Wayland, X11, Win32, NSPasteboard)",
	.open = &open,
	.close = &live::close{clipboard::Clipboard, clipboard::State, clipboard::Cap},
	.state = &live::state{clipboard::Clipboard, clipboard::State, clipboard::Cap},
	.state_after = &live::state_after{clipboard::Clipboard, clipboard::State, clipboard::Cap},
	.capabilities = &live::capabilities{clipboard::Clipboard, clipboard::State, clipboard::Cap},
	.backend = &live::backend{clipboard::Clipboard, clipboard::State, clipboard::Cap},
	.watch = &tap::watch{clipboard::Clipboard, clipboard::State},
	.commands = COMMANDS[..],
};