module bleu::tray @feat(DARWIN);
import bleu::tray::appkit;

alias DriverList = Driver*[1];
DriverList darwin_driver_list = { &appkit::DRIVER };

fn Driver*[] darwin_drivers() => darwin_driver_list[..];