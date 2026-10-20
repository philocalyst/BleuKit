module bleu::tray @feat(WIN32);
import bleu::tray::win32;

alias DriverList = Driver*[1];
DriverList windows_driver_list = { &win32::DRIVER };

fn Driver*[] windows_drivers() => windows_driver_list[..];
