module bleu::clipboard @feat(DARWIN);
import bleu::clipboard::macos_pasteboard;

alias DriverList = Driver*[1];
DriverList darwin_driver_list = { &macos_pasteboard::DRIVER };

fn Driver*[] darwin_drivers() => darwin_driver_list[..];