module bleu::battery @feat(DARWIN);
import bleu::battery::iokit;

alias DriverList = Driver*[1];
DriverList darwin_driver_list = { &iokit::DRIVER };

fn Driver*[] darwin_drivers() => darwin_driver_list[..];
