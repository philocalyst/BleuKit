module bleu::secrets @feat(DARWIN);
import bleu::secrets::mac;

alias DriverList = Driver*[1];
DriverList macos_driver_list = { &mac::DRIVER };

fn Driver*[] macos_drivers() => macos_driver_list[..];