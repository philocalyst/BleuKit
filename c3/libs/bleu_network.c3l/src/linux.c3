module bleu::network @feat(LINUX);
import bleu::network::networkmanager;

alias DriverList = Driver*[1];
DriverList linux_driver_list = { &networkmanager::DRIVER };

<*
 Linux backends, best first: NetworkManager. iwd and wpa_supplicant are deferred (docs/research/network.md section 6).
*>
fn Driver*[] linux_drivers() => linux_driver_list[..];