module bleu::tray @feat(WIN32);
import bleu::tray::windows_tray;

alias DriverList = Driver*[1];
DriverList windows_driver_list = { &windows_tray::DRIVER };

fn Driver*[] windows_drivers() => windows_driver_list[..];
