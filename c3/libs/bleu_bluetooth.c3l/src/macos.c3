module bleu::bluetooth @feat(DARWIN);

alias DriverList = Driver*[1];
DriverList macos_driver_list = { &iobluetooth::DRIVER };

<* The macOS backends, best first. IOBluetooth is the only one in this build. *>
fn Driver*[] platform_drivers() => macos_driver_list[..];
