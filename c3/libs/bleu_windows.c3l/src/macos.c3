module bleu::windows @feat(DARWIN);
import bleu::windows::macos_workspace;

alias DriverList = Driver*[1];
DriverList darwin_driver_list = { &macos_workspace::DRIVER };

fn Driver*[] darwin_drivers() => darwin_driver_list[..];