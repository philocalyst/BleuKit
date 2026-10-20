module bleu::battery @feat(LINUX);
import bleu::battery::upower, bleu::battery::sysfs;

alias DriverList = Driver*[2];
DriverList linux_driver_list = { &upower::DRIVER, &sysfs::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];