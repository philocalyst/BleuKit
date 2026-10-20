<*
 Windows sender: refused, with the reason. The toast path (WinRT
 ToastNotificationManager) needs interface IDs and vtable slots for four WinRT
 interfaces that this library has not cited from two sources, and a desktop app
 must also have a Start-menu shortcut that carries its AppUserModelID.
 docs/research/media_notify_tray.md section 2.3 cites the Microsoft pages only.
*>
module bleu::notify::sender_toast @feat(WIN32);
import bleu::availability, bleu::error, bleu::notify, bleu::notify::sender;

const String TOAST_REASON = "Windows toasts are not implemented: the WinRT ToastNotificationManager bindings are not cited from two sources, and desktop apps need a Start-menu shortcut with an AppUserModelID";

const sender::SenderDriver DRIVER = {
	.info = { "toast", "Windows toast notifications (not implemented)", 0 },
	.open_fn = &open_toast,
	.close_fn = &close_toast,
	.send_fn = &send_toast,
};

fn void*? open_toast(Allocator allocator, sender::Features* features)
{
	features.init(availability::no(availability::Reason.UNSUPPORTED_BACKEND, TOAST_REASON));
	return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "%s", TOAST_REASON)~;
}

// Never reached: `open_toast` never succeeds, so there is no sender state to close.
fn void close_toast(Allocator allocator, void* state)
{
	unreachable("the toast sender never opens");
}

// Never reached for the same reason as `close_toast`.
fn notify::NoteId? send_toast(void* state, sender::Request* request)
{
	return error::UNSUPPORTED~;
}