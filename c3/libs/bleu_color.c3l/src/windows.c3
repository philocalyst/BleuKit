module bleu::color @feat(WIN32);
import bleu::color::windows_ramp;

alias DriverList = Driver*[1];
DriverList windows_driver_list = { &windows_ramp::DRIVER };

fn Driver*[] windows_drivers() => windows_driver_list[..];
