module bleu::battery @feat(LINUX);

alias DriverList = Driver*[1];
DriverList linux_driver_list = { &sysfs::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];