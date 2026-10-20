module bleu::media @feat(WIN32);

alias DriverList = Driver*[1];
DriverList windows_driver_list = { &smtc::DRIVER };

fn Driver*[] windows_drivers() => windows_driver_list[..];