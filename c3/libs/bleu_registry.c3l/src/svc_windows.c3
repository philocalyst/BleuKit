<* The `windows` entry of the registry: open adapter, commands and `Spec`. *>
module bleu::registry::svc_windows;
import bleu::windows, bleu::registry, bleu::registry::live, bleu::json, bleu::operation, bleu::registry::tap;

<* Open the window service with its default backend. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	windows::Windows* service = windows::open(allocator)!;
	return (void*)service;
}

<* Wait for a window command and write the success object. *>
fn void? finish(registry::Request* request, Operation{bool}* operation) @private
{
	defer operation.release();
	registry::await{bool}(operation, request.timeout)!;
	return registry::write_ok(request.out);
}

<* `windows.focus {window}`: raise a window and give it focus. *>
fn void? focus(registry::Request* request)
{
	windows::Windows* service = (windows::Windows*)request.handle;
	return finish(request, service.focus_window(request.params.string("window")!)!);
}

<* `windows.close {window}`: ask a window to close. *>
fn void? close(registry::Request* request)
{
	windows::Windows* service = (windows::Windows*)request.handle;
	return finish(request, service.close_window(request.params.string("window")!)!);
}

<* `windows.switch_workspace {workspace}`: show a workspace. *>
fn void? switch_workspace(registry::Request* request)
{
	windows::Windows* service = (windows::Windows*)request.handle;
	return finish(request, service.switch_workspace(request.params.string("workspace")!)!);
}

const registry::Command[3] COMMANDS = {
	{ .name = "windows.focus", .summary = "Focus a window: {window}.", .run = &focus },
	{ .name = "windows.close", .summary = "Close a window: {window}.", .run = &close },
	{ .name = "windows.switch_workspace", .summary = "Show a workspace: {workspace}.", .run = &switch_workspace },
};

const registry::Spec WINDOWS = {
	.name = "windows",
	.summary = "Windows, workspaces and focus (Wayland compositors, X11 EWMH, macOS, Win32)",
	.open = &open,
	.close = &live::close{windows::Windows, windows::State, windows::Cap},
	.state = &live::state{windows::Windows, windows::State, windows::Cap},
	.capabilities = &live::capabilities{windows::Windows, windows::State, windows::Cap},
	.backend = &live::backend{windows::Windows, windows::State, windows::Cap},
	.watch = &tap::watch{windows::Windows, windows::State},
	.commands = COMMANDS[..],
};