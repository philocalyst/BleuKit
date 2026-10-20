module bleu::color @feat(LINUX);
import bleu::color::linux_wlr;

alias DriverList = Driver*[1];
DriverList linux_driver_list = { &linux_wlr::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];