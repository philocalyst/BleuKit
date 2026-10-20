module bleu::network @feat(DARWIN);
import bleu::network::corewlan;

alias DriverList = Driver*[1];
DriverList macos_driver_list = { &corewlan::DRIVER };

<*
 macOS backends, best first: CoreWLAN. The Apple80211 private framework is not used in v1 (docs/research/network.md
 section 6).
*>
fn Driver*[] macos_drivers() => macos_driver_list[..];