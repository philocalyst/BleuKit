module bleu::hotkey @feat(LINUX);
import bleu::hotkey::portal;

alias DriverList = Driver*[1];
DriverList linux_driver_list = { &portal::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];
