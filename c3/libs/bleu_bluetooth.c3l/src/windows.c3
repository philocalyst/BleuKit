module bleu::bluetooth @feat(WIN32);

alias DriverList = Driver*[1];
DriverList windows_driver_list = { &win32_backend::DRIVER };

<* The Windows backends, best first. The Win32 Bluetooth functions are the only one in this build. *>
fn Driver*[] platform_drivers() => windows_driver_list[..];