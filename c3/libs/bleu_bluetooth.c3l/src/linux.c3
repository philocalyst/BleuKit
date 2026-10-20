module bleu::bluetooth @feat(LINUX);

alias DriverList = Driver*[1];
DriverList linux_driver_list = { &bluez::DRIVER };

<* The Linux backends, best first. BlueZ is the only one in this build. *>
fn Driver*[] platform_drivers() => linux_driver_list[..];