module bleu::audio @feat(LINUX);
import bleu::audio::linux_pulse;

alias DriverList = Driver*[1];
DriverList linux_driver_list = { &linux_pulse::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];