module bleu::network @feat(WIN32);
import bleu::network::wlan_api;

alias DriverList = Driver*[1];
DriverList windows_driver_list = { &wlan_api::DRIVER };

<* Windows backends, best first: the Native Wifi (WLAN) API. *>
fn Driver*[] windows_drivers() => windows_driver_list[..];