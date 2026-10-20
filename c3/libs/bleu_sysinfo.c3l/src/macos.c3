module bleu::sysinfo @feat(DARWIN);

alias DriverList = Driver*[1];
DriverList macos_driver_list = { &mach::DRIVER };

fn Driver*[] macos_drivers() => macos_driver_list[..];
