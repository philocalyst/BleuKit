module bleu::clipboard @feat(WIN32);
import bleu::clipboard::windows_clipboard;

alias DriverList = Driver*[1];
DriverList windows_driver_list = { &windows_clipboard::DRIVER };

fn Driver*[] windows_drivers() => windows_driver_list[..];