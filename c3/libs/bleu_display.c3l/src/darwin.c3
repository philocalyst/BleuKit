module bleu::display @feat(DARWIN);
import bleu::display::coregraphics;

alias DriverList = Driver*[1];
DriverList darwin_driver_list = { &coregraphics::DRIVER };

fn Driver*[] darwin_drivers() => darwin_driver_list[..];
