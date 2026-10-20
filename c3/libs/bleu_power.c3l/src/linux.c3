module bleu::power @feat(LINUX);

alias DriverList = Driver*[1];
DriverList linux_driver_list = { &logind::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];