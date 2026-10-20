module bleu::session @feat(LINUX);
import bleu::session::logind;

alias DriverList = Driver*[1];
DriverList linux_driver_list = { &logind::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];
