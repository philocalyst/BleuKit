module bleu::apps @feat(LINUX);
import bleu::apps::xdg_desktop;

<* Linux backends, best first. *>
alias DriverList = Driver*[1];
DriverList linux_driver_list = { &xdg_desktop::DRIVER };

fn Driver*[] linux_drivers() => linux_driver_list[..];
