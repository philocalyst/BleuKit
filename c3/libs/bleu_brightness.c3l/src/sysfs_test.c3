module bleu::brightness::sysfs_test;
import bleu::brightness::sysfs;

fn void backlight_types_rank_firmware_then_platform_then_raw() @test
{
	assert(sysfs::type_rank("firmware") > sysfs::type_rank("platform"));
	assert(sysfs::type_rank("platform") > sysfs::type_rank("raw"));
	assert(sysfs::type_rank("raw") > sysfs::type_rank("unknown-type"));
}

fn void best_backlight_is_the_highest_rank_then_the_first_name() @test
{
	int[] ranks    = { 1, 3, 2 };
	String[] names = { "acpi_video0", "intel_backlight", "nv_backlight" };
	assert(sysfs::select_best(ranks, names) == 1, "firmware wins over raw and platform");
	int[] tied          = { 3, 3 };
	String[] tied_names = { "zz_panel", "aa_panel" };
	assert(sysfs::select_best(tied, tied_names) == 1, "ties go to the name that sorts first");
	int[] none        = { };
	String[] no_names = { };
	assert(sysfs::select_best(none, no_names) == -1, "no candidates is -1");
}

fn void keyboard_backlight_names() @test
{
	assert(sysfs::is_keyboard_backlight("input5::kbd_backlight"));
	assert(sysfs::is_keyboard_backlight(":kbd_backlight"));
	assert(!sysfs::is_keyboard_backlight("input5::capslock"));
}

fn void connector_names() @test
{
	assert(sysfs::is_connector_name("card1-DP-1"));
	assert(sysfs::is_connector_name("card0-eDP-1"));
	assert(!sysfs::is_connector_name("card0"));
	assert(!sysfs::is_connector_name("renderD128"));
	assert(!sysfs::is_connector_name("card1-"));
	assert(!sysfs::is_connector_name("cardX-DP-1"));
}

fn void bus_comes_from_the_link_leaf() @test
{
	assert((sysfs::bus_from_link("../../../../bus/i2c/devices/i2c-7") ?? -1) == 7);
	assert((sysfs::bus_from_link("i2c-12") ?? -1) == 12);
	assert(@catch(sysfs::bus_from_link("../devices/pci0000:00")) == NOT_FOUND);
	assert(@catch(sysfs::bus_from_link("i2c-")) == NOT_FOUND);
	assert(@catch(sysfs::bus_from_link("i2c-7x")) == NOT_FOUND);
}

fn void bus_numbers_have_at_most_nine_digits() @test
{
	int bus = sysfs::bus_from_link("../../devices/i2c-123456789")!!;
	assert(bus == 123456789, "nine digits fit an int");
	if (catch err = sysfs::bus_from_link("../../devices/i2c-1234567890"))
	{
		assert(err == NOT_FOUND, "ten digits would overflow an int and are refused");
	}
	else
	{
		assert(false, "an overlong bus number must not be accepted");
	}
}
