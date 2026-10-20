module bleu::session @feat(DARWIN);
import bleu::session::macos;

alias DriverList = Driver*[1];
DriverList darwin_driver_list = { &macos::DRIVER };

fn Driver*[] darwin_drivers() => darwin_driver_list[..];
