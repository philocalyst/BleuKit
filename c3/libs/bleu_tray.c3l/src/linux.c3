module bleu::tray @feat(LINUX);
import bleu::tray::sni;

alias DriverList = Driver*[1];
DriverList linux_driver_list = { &sni::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];