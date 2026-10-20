module bleu::brightness @feat(LINUX);

alias DriverList = Driver*[1];
DriverList linux_driver_list = { &linux::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];
