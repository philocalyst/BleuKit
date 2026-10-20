module bleu::media @feat(DARWIN);

alias DriverList = Driver*[1];
DriverList macos_driver_list = { &scripting::DRIVER };

fn Driver*[] macos_drivers() => macos_driver_list[..];