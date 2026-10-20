module bleu::display @feat(WIN32);
import bleu::display::windows_config;

alias DriverList = Driver*[1];
DriverList windows_driver_list = { &windows_config::DRIVER };

fn Driver*[] windows_drivers() => windows_driver_list[..];