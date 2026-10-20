module bleu::clipboard @feat(LINUX);
import bleu::clipboard::linux_wl;

alias DriverList = Driver*[1];
DriverList linux_driver_list = { &linux_wl::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];
