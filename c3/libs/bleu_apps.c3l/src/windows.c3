module bleu::apps @feat(WIN32);
import bleu::apps::start_menu;

<* Windows backends, best first. *>
alias DriverList = Driver*[1];
DriverList windows_driver_list = { &start_menu::DRIVER };

fn Driver*[] windows_drivers() => windows_driver_list[..];