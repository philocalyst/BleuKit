module bleu::hotkey @feat(DARWIN);
import bleu::hotkey::carbon;

alias DriverList = Driver*[1];
DriverList darwin_driver_list = { &carbon::DRIVER };

fn Driver*[] darwin_drivers() => darwin_driver_list[..];
