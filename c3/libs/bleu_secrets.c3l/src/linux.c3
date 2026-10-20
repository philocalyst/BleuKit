module bleu::secrets @feat(LINUX);
import bleu::secrets::ss;

alias DriverList = Driver*[1];
DriverList linux_driver_list = { &ss::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];