<*
 The registry table: every service, in the order `bleud --list` prints them.

 Adding a service: write `svc_<name>.c3` (an open adapter, its commands and a
 `Spec`), then add its `Spec` here and its library to the manifest.
*>
module bleu::registry;
import bleu::registry::svc_battery, bleu::registry::svc_power, bleu::registry::svc_network,
	bleu::registry::svc_bluetooth, bleu::registry::svc_audio, bleu::registry::svc_brightness,
	bleu::registry::svc_display, bleu::registry::svc_color, bleu::registry::svc_media,
	bleu::registry::svc_notify, bleu::registry::svc_tray, bleu::registry::svc_session,
	bleu::registry::svc_apps, bleu::registry::svc_sysinfo, bleu::registry::svc_clipboard,
	bleu::registry::svc_windows, bleu::registry::svc_secrets, bleu::registry::svc_appearance,
	bleu::registry::svc_hotkey, bleu::registry::svc_input;

<* The number of services in `SERVICES`. *>
const usz SERVICE_COUNT = 20;

<* Every service the registry exposes, in table order. *>
const Spec*[SERVICE_COUNT] SERVICES = {
	&svc_battery::BATTERY, &svc_power::POWER, &svc_network::NETWORK,
	&svc_bluetooth::BLUETOOTH, &svc_audio::AUDIO, &svc_brightness::BRIGHTNESS,
	&svc_display::DISPLAY, &svc_color::COLOR, &svc_media::MEDIA,
	&svc_notify::NOTIFY, &svc_tray::TRAY, &svc_session::SESSION,
	&svc_apps::APPS, &svc_sysinfo::SYSINFO, &svc_clipboard::CLIPBOARD,
	&svc_windows::WINDOWS, &svc_secrets::SECRETS, &svc_appearance::APPEARANCE,
	&svc_hotkey::HOTKEY, &svc_input::INPUT,
};

