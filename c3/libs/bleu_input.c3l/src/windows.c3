module bleu::input @feat(WIN32);
import bleu::input::windows_klayout;

alias DriverList = Driver*[1];
DriverList windows_driver_list = { &windows_klayout::DRIVER };

fn Driver*[] windows_drivers() => windows_driver_list[..];
