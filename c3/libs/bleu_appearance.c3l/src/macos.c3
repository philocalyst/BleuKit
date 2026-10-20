module bleu::appearance @feat(DARWIN);
import bleu::appearance::appkit;

alias MacDriverList = Driver*[1];
MacDriverList macos_driver_list = { &appkit::DRIVER };

fn Driver*[] macos_drivers() => macos_driver_list[..];