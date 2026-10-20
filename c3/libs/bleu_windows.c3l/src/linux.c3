module bleu::windows @feat(LINUX);
import bleu::windows::linux_compositor;

alias DriverList = Driver*[1];
DriverList linux_driver_list = { &linux_compositor::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];
