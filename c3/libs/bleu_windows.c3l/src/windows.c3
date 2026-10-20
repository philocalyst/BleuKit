module bleu::windows @feat(WIN32);
import bleu::windows::win32_enum;

alias DriverList = Driver*[1];
DriverList windows_driver_list = { &win32_enum::DRIVER };

fn Driver*[] windows_drivers() => windows_driver_list[..];