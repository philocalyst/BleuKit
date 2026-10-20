module bleu::media @feat(LINUX);

alias DriverList = Driver*[1];
DriverList linux_driver_list = { &mpris::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];