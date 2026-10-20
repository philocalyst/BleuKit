module bleu::power @feat(DARWIN);

alias DriverList = Driver*[1];
DriverList macos_driver_list = { &macos::DRIVER };

fn Driver*[] macos_drivers() => macos_driver_list[..];