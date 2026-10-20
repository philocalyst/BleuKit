module bleu::battery @feat(WIN32);
import bleu::battery::win32;

alias DriverList = Driver*[1];
DriverList windows_driver_list = { &win32::DRIVER };

fn Driver*[] windows_drivers() => windows_driver_list[..];