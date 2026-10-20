// The macOS sender of this platform, for the platform list in `sender_probe.c3`.
module bleu::notify::sender @feat(DARWIN);
import bleu::notify::sender_un;

fn SenderDriver* darwin_sender_driver() => &sender_un::DRIVER;
