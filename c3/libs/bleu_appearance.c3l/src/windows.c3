module bleu::appearance @feat(WIN32);
import bleu::appearance::windows;

alias WindowsDriverList = Driver*[1];
WindowsDriverList windows_driver_list = { &windows::DRIVER };

fn Driver*[] windows_drivers() => windows_driver_list[..];