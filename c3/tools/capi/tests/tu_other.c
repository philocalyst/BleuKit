/* The second translation unit: it uses types and constants from the same headers. */
#include <bleu/bleu.h>
#include <bleu/battery.h>
#include <bleu/brightness.h>

int tu_other_check(void)
{
    bleu_battery_options_t battery = { 0 };
    bleu_brightness_options_t brightness = { 0 };
    battery.struct_size = sizeof battery;
    brightness.struct_size = sizeof brightness;
    if (battery.backend != BLEU_BATTERY_BACKEND_AUTO) return 1;
    if (brightness.backend != BLEU_BRIGHTNESS_BACKEND_AUTO) return 1;
    return bleu_status_name(BLEU_STATUS_OK)[0] == 'O' ? 0 : 1;
}
