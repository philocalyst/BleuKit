module bleu::display @feat(LINUX);
import bleu::display::linux_wayland;

alias DriverList = Driver*[1];
DriverList linux_driver_list = { &linux_wayland::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];
