// The Windows sender of this platform, for the platform list in `sender_probe.c3`.
module bleu::notify::sender @feat(WIN32);
import bleu::notify::sender_toast;

fn SenderDriver* windows_sender_driver() => &sender_toast::DRIVER;
