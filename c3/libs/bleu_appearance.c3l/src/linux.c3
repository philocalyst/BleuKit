module bleu::appearance @feat(LINUX);
import bleu::appearance::portal, bleu::appearance::gsettings;

alias LinuxDriverList = Driver*[2];
LinuxDriverList linux_driver_list = { &portal::DRIVER, &gsettings::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];