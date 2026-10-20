module bleu::hotkey @feat(WIN32);
import bleu::hotkey::windows;

alias DriverList = Driver*[1];
DriverList windows_driver_list = { &windows::DRIVER };

fn Driver*[] windows_drivers() => windows_driver_list[..];