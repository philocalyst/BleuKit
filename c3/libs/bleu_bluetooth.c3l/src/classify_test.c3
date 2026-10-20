module bleu::bluetooth::classify_test;
import std::collections::maybe, bleu::unit, bleu::bluetooth;

fn void class_of_device_names_the_icon() @test
{
	// Peripheral major class; keyboard bit (minor 0x10 shifted to class bit 6).
	assert(bleu::bluetooth::icon_from_class(0x540) == KEYBOARD);
	// Peripheral pointing device (minor 0x20).
	assert(bleu::bluetooth::icon_from_class(0x580) == MOUSE);
	// Audio/video, headphones (minor 0x06).
	assert(bleu::bluetooth::icon_from_class(0x418) == HEADPHONES);
	// Audio/video, headset (minor 0x01).
	assert(bleu::bluetooth::icon_from_class(0x404) == HEADSET);
	// Phone, smartphone (minor 0x03).
	assert(bleu::bluetooth::icon_from_class(0x20C) == PHONE);
	// Computer, laptop (minor 0x03).
	assert(bleu::bluetooth::icon_from_class(0x10C) == COMPUTER);
	// Imaging, printer bit (minor 0x20 -> class bit 7).
	assert(bleu::bluetooth::icon_from_class(0x680) == PRINTER);
	// Unknown class: zero.
	assert(bleu::bluetooth::icon_from_class(0) == UNKNOWN);
}

fn void appearance_names_the_icon_when_class_does_not() @test
{
	assert(bleu::bluetooth::icon_from_appearance(0x03C1) == KEYBOARD);
	assert(bleu::bluetooth::icon_from_appearance(0x03C2) == MOUSE);
	assert(bleu::bluetooth::icon_from_appearance(0x03C4) == GAMEPAD);
	assert(bleu::bluetooth::icon_from_appearance(0x00C0) == WATCH);
	assert(bleu::bluetooth::icon_from_appearance(0) == UNKNOWN);
	// The class wins when it names something.
	assert(bleu::bluetooth::icon_of(0x540, 0x03C2) == KEYBOARD);
	assert(bleu::bluetooth::icon_of(0, 0x03C2) == MOUSE);
}

fn void battery_above_one_hundred_is_no_reading() @test
{
	assert(bleu::bluetooth::battery_level(255).has_value == false);
	assert(bleu::bluetooth::battery_level(101).has_value == false);
	Maybe{Level} full = bleu::bluetooth::battery_level(100);
	assert(full.has_value && (float)full.value == 1.0f);
	Maybe{Level} empty = bleu::bluetooth::battery_level(0);
	assert(empty.has_value && (float)empty.value == 0.0f);
}

fn void modalias_gives_vendor_and_product() @test
{
	Maybe{PnpId} usb = bleu::bluetooth::parse_modalias("usb:v1D6Bp0246d0533");
	assert(usb.has_value);
	assert(usb.value.source == USB);
	assert(usb.value.vendor == 0x1D6B && usb.value.product == 0x0246 && usb.value.version == 0x0533);
	Maybe{PnpId} bt = bleu::bluetooth::parse_modalias("bluetooth:v004Cp0000d0100");
	assert(bt.has_value && bt.value.source == BLUETOOTH && bt.value.vendor == 0x004C);
}

fn void malformed_modalias_is_no_identity() @test
{
	assert(bleu::bluetooth::parse_modalias("").has_value == false);
	assert(bleu::bluetooth::parse_modalias("usb:1D6Bp0246d0533").has_value == false);
	assert(bleu::bluetooth::parse_modalias("usb:v1D6Bp02").has_value == false);
	assert(bleu::bluetooth::parse_modalias("usb:v1D6Bp02G6d0533").has_value == false);
}
