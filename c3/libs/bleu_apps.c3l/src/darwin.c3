module bleu::apps @feat(DARWIN);
import bleu::apps::app_bundles;

<* macOS backends, best first. *>
alias DriverList = Driver*[1];
DriverList darwin_driver_list = { &app_bundles::DRIVER };

fn Driver*[] darwin_drivers() => darwin_driver_list[..];
