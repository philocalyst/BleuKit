module bleu::input @feat(LINUX);
import bleu::input::linux_compositor, bleu::input::linux_locale1;

alias DriverList = Driver*[2];
DriverList linux_driver_list = { &linux_compositor::DRIVER, &linux_locale1::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];