// The Linux sender of this platform, for the platform list in `sender_probe.c3`.
module bleu::notify::sender @feat(LINUX);
import bleu::notify::sender_fdo;

fn SenderDriver* linux_sender_driver() => &sender_fdo::DRIVER;