module bleu::input @feat(DARWIN);
import bleu::input::macos_tis;

alias DriverList = Driver*[1];
DriverList darwin_driver_list = { &macos_tis::DRIVER };

fn Driver*[] darwin_drivers() => darwin_driver_list[..];