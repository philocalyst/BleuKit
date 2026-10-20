module bleu::sysinfo @feat(LINUX);

alias DriverList = Driver*[1];
DriverList linux_driver_list = { &procfs::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];