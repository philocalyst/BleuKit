module bleu::notify @feat(LINUX);
import bleu::notify::fdo;

alias DriverList = Driver*[1];
DriverList linux_driver_list = { &fdo::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];
