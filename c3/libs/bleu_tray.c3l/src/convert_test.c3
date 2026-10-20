module bleu::tray::convert_test;
import bleu::error, bleu::tray, bleu::tray::convert;

// Asserts that the expression fails with `expected`.
macro @expect_fault(#result, expected)
{
	bool failed = false;
	if (catch err = #result)
	{
		assert(err == expected);
		failed = true;
	}
	assert(failed);
}

// A 3 by 1 image: the height is 1, so the size check reads 3 * 1 * 4 = 12 bytes.
fn void rgba_of_a_non_square_icon() @test
{
	char[12] pixels = { 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC };
	convert::argb_to_rgba(pixels[..], 3, 1)!!;
	assert(pixels[0] == 0x22 && pixels[1] == 0x33 && pixels[2] == 0x44 && pixels[3] == 0x11);
	assert(pixels[8] == 0xAA && pixels[9] == 0xBB && pixels[10] == 0xCC && pixels[11] == 0x99);
}

// A tall icon, to check the height is not read from the width.
fn void rgba_of_a_tall_icon() @test
{
	char[8] pixels = { 1, 2, 3, 4, 5, 6, 7, 8 };
	convert::argb_to_rgba(pixels[..], 1, 2)!!;
	assert(pixels[0] == 2 && pixels[3] == 1 && pixels[4] == 6 && pixels[7] == 5);
}

fn void size_mismatch_is_refused() @test
{
	char[8] pixels;
	@expect_fault(convert::argb_to_rgba(pixels[..], 3, 1), error::INVALID_ARGUMENT);
	@expect_fault(convert::argb_to_rgba(pixels[..], 0, 2), error::INVALID_ARGUMENT);
	assert(!convert::pixmap_fits(convert::MAX_ICON_EDGE + 1, 1, (usz)(convert::MAX_ICON_EDGE + 1) * 4));
	assert(convert::pixmap_fits(2, 1, 8));
}

fn void mnemonics_follow_libdbusmenu() @test
{
	assert(convert::mnemonic_free("_Open", tmem) == "Open");
	assert(convert::mnemonic_free("Sa_ve", tmem) == "Save");
	assert(convert::mnemonic_free("A__B", tmem) == "A_B");
	assert(convert::mnemonic_free("__", tmem) == "_");
	assert(convert::mnemonic_free("_", tmem) == "");
	assert(convert::mnemonic_free("", tmem) == "");
	assert(convert::mnemonic_free("Plain", tmem) == "Plain");
}

fn void registrations_in_every_form() @test
{
	convert::Registration a = convert::parse_registration("org.app.Tray", ":1.5")!!;
	assert(a.bus_name == "org.app.Tray" && a.object_path == "/StatusNotifierItem");
	convert::Registration b = convert::parse_registration(":1.72/org/ayatana/NotificationItem/x", ":1.9")!!;
	assert(b.bus_name == ":1.72" && b.object_path == "/org/ayatana/NotificationItem/x");
	convert::Registration c = convert::parse_registration("/StatusNotifierItem", ":1.9")!!;
	assert(c.bus_name == ":1.9" && c.object_path == "/StatusNotifierItem");
	@expect_fault(convert::parse_registration("", ":1.9"), error::INVALID_ARGUMENT);
	@expect_fault(convert::parse_registration("bad name!/x", ":1.9"), error::INVALID_ARGUMENT);
	@expect_fault(convert::parse_registration("/StatusNotifierItem", ""), error::INVALID_ARGUMENT);
}

fn void registration_joins_as_the_watcher_stores_it() @test
{
	convert::Registration r = convert::parse_registration("org.app/Item", ":1.1")!!;
	assert(convert::item_id(r, tmem) == "org.app/Item");
}

fn void enumerated_text_is_read_with_defaults() @test
{
	assert(convert::status_from("NeedsAttention") == NEEDS_ATTENTION);
	assert(convert::status_from("Whatever") == PASSIVE);
	assert(convert::category_from("Hardware") == HARDWARE);
	assert(convert::category_from("") == UNKNOWN);
	assert(convert::toggle_from("radio") == RADIO);
	assert(convert::toggle_state_from(-1) == INDETERMINATE);
	assert(convert::toggle_state_from(1) == ON);
	assert(convert::disposition_from("alert") == ALERT);
}

fn void win32_labels_use_ampersands() @test
{
	assert(convert::win32_label("_Open", tmem) == "&Open");
	assert(convert::win32_label("Item __one", tmem) == "Item _one");
	assert(convert::win32_label("A&B", tmem) == "A&&B");
	assert(convert::win32_label("", tmem) == "");
}
