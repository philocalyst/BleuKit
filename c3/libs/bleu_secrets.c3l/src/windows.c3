module bleu::secrets @feat(WIN32);
import bleu::secrets::win;

alias DriverList = Driver*[1];
DriverList windows_driver_list = { &win::DRIVER };

fn Driver*[] windows_drivers() => windows_driver_list[..];