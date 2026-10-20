module bleu::notify::hints_test;
import bleu::dbus::marshal, bleu::notify, bleu::notify::hints;

// Encodes `a{sv}` entries: each helper appends one dictionary entry.
fn void put_string(Writer* w, String key, String value)
{
	w.begin_dict_entry()!!;
	w.append_string(key)!!;
	w.begin_variant("s")!!;
	w.append_string(value)!!;
	w.end_variant()!!;
	w.end_dict_entry()!!;
}

fn void put_scalar(Writer* w, String key, String type, ulong bits)
{
	w.begin_dict_entry()!!;
	w.append_string(key)!!;
	w.begin_variant(type)!!;
	if (type == "b") w.append_bool(bits != 0)!!;
	if (type == "y") w.append_byte((char)bits)!!;
	if (type == "i") w.append_i32((int)bits)!!;
	if (type == "u") w.append_u32((uint)bits)!!;
	w.end_variant()!!;
	w.end_dict_entry()!!;
}

// An `(iiibiiay)` image with the given header and `count` pixel bytes, each set to `fill`.
fn void put_image(
	Writer* w,
	String key,
	int width,
	int height,
	int rowstride,
	bool alpha,
	int bits,
	int channels,
	usz count,
	char fill
)
{
	w.begin_dict_entry()!!;
	w.append_string(key)!!;
	w.begin_variant("(iiibiiay)")!!;
	w.begin_struct()!!;
	w.append_i32(width)!!;
	w.append_i32(height)!!;
	w.append_i32(rowstride)!!;
	w.append_bool(alpha)!!;
	w.append_i32(bits)!!;
	w.append_i32(channels)!!;
	w.begin_array("ay")!!;
	for (usz k = 0; k < count; k++) w.append_byte(fill)!!;
	w.end_array()!!;
	w.end_struct()!!;
	w.end_variant()!!;
	w.end_dict_entry()!!;
}

// Decode the hints that `w` encoded, inside a temporary pool.
fn void decode_into(Writer* w, Hints* out)
{
	w.finish()!!;
	Reader r;
	r.init(w.bytes(), "a{sv}")!!;
	hints::decode(&r, tmem, out)!!;
}

fn void known_hints_are_read() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "a{sv}")!!;
		w.begin_array("a{sv}")!!;
		put_scalar(&w, "urgency", "y", 2);
		put_string(&w, "category", "im.received");
		put_string(&w, "desktop-entry", "chat");
		put_scalar(&w, "resident", "b", 1);
		put_scalar(&w, "transient", "b", 1);
		put_scalar(&w, "suppress-sound", "b", 1);
		put_string(&w, "sound-name", "message-new-instant");
		put_string(&w, "sound-file", "/x.oga");
		put_scalar(&w, "value", "i", 40);
		put_string(&w, "x-canonical-private-synchronous", "chat-1");
		w.end_array()!!;
		Hints h;
		decode_into(&w, &h);
		assert(h.urgency == notify::Urgency.CRITICAL);
		assert(h.category == "im.received");
		assert(h.desktop_entry == "chat");
		assert(h.resident && h.transient && h.suppress_sound);
		assert(h.sound_name == "message-new-instant");
		assert(h.sound_file == "/x.oga");
		assert(h.progress.has_value && (float)h.progress.value > 0.39f && (float)h.progress.value < 0.41f);
		assert(h.stack_tag == "chat-1");
		assert(h.ignored == 0);
		assert(!h.has_image);
	};
}

fn void wrong_types_are_skipped_and_counted() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "a{sv}")!!;
		w.begin_array("a{sv}")!!;
		put_string(&w, "urgency", "urgent");
		put_scalar(&w, "resident", "i", 1);
		put_scalar(&w, "value", "b", 1);
		put_string(&w, "image-path", "/ok.png");
		w.end_array()!!;
		Hints h;
		decode_into(&w, &h);
		assert(h.urgency == notify::Urgency.NORMAL);
		assert(!h.resident);
		assert(!h.progress.has_value);
		assert(h.image_path == "/ok.png");
		assert(h.ignored == 3);
	};
}

fn void unknown_hints_are_ignored_without_counting() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "a{sv}")!!;
		w.begin_array("a{sv}")!!;
		put_string(&w, "x-vendor-whatever", "v");
		put_scalar(&w, "action-icons", "b", 1);
		put_scalar(&w, "x", "i", 10);
		w.end_array()!!;
		Hints h;
		decode_into(&w, &h);
		assert(h.ignored == 0);
		assert(h.urgency == notify::Urgency.NORMAL);
	};
}

fn void image_data_is_decoded_and_copied() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "a{sv}")!!;
		w.begin_array("a{sv}")!!;
		// 2x2 RGB with 8 bytes of padding per row: 6 + 2*... needs 6*(2-1) + 2*3 = 12 bytes.
		put_image(&w, "image-data", 2, 2, 6, false, 8, 3, 12, 'z');
		w.end_array()!!;
		Hints h;
		decode_into(&w, &h);
		assert(h.has_image);
		assert(h.image.width == 2 && h.image.height == 2 && h.image.rowstride == 6);
		assert(!h.image.has_alpha && h.image.channels == 3);
		assert(h.image.pixels.len == 12);
		assert(h.image.pixels[11] == 'z');
	};
}

fn void invalid_images_are_dropped_and_counted() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "a{sv}")!!;
		w.begin_array("a{sv}")!!;
		put_image(&w, "image-data", 2, 2, 6, false, 16, 3, 12, 0); // bits per sample must be 8
		put_image(&w, "icon_data", 2, 2, 6, true, 8, 3, 12, 0); // alpha needs 4 channels
		put_image(&w, "image_data", 2, 2, 5, false, 8, 3, 12, 0); // a row is 6 bytes at least
		put_image(&w, "image-data", 1000, 1000, 4000, true, 8, 4, 4000000, 0);
		w.end_array()!!;
		Hints h;
		decode_into(&w, &h);
		assert(!h.has_image);
		assert(h.ignored == 4);
	};
}

fn void short_pixel_data_is_dropped() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "a{sv}")!!;
		w.begin_array("a{sv}")!!;
		put_image(&w, "image-data", 2, 2, 6, false, 8, 3, 5, 0); // needs 12 bytes
		w.end_array()!!;
		Hints h;
		decode_into(&w, &h);
		assert(!h.has_image);
		assert(h.ignored == 1);
	};
}

fn void the_newer_image_name_wins_whatever_the_order() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "a{sv}")!!;
		w.begin_array("a{sv}")!!;
		put_image(&w, "icon_data", 1, 1, 3, false, 8, 3, 3, 'i');
		put_image(&w, "image-data", 2, 1, 6, false, 8, 3, 6, 'd');
		put_image(&w, "image_data", 3, 1, 9, false, 8, 3, 9, 'u');
		w.end_array()!!;
		Hints h;
		decode_into(&w, &h);
		assert(h.image.width == 2);
		assert(h.image.pixels[0] == 'd');
	};
}

fn void image_path_prefers_its_current_name() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "a{sv}")!!;
		w.begin_array("a{sv}")!!;
		put_string(&w, "image-path", "/new.png");
		put_string(&w, "image_path", "/old.png");
		w.end_array()!!;
		Hints h;
		decode_into(&w, &h);
		assert(h.image_path == "/new.png");
	};
}

fn void stack_tags_prefer_the_most_specific_name() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "a{sv}")!!;
		w.begin_array("a{sv}")!!;
		put_string(&w, "synchronous", "plain");
		put_string(&w, "x-canonical-private-synchronous", "canonical");
		put_string(&w, "x-dunst-stack-tag", "dunst");
		w.end_array()!!;
		Hints h;
		decode_into(&w, &h);
		assert(h.stack_tag == "canonical");
	};
}

fn void progress_is_clamped_to_a_percentage() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "a{sv}")!!;
		w.begin_array("a{sv}")!!;
		put_scalar(&w, "value", "u", 150);
		w.end_array()!!;
		Hints h;
		decode_into(&w, &h);
		assert(h.progress.has_value && (float)h.progress.value == 1.0f);
	};
}

fn void long_strings_are_truncated() @test
{
	@pool()
	{
		DString long_name;
		long_name.init(tmem);
		for (int k = 0; k < 200; k++) long_name.append_char('c');
		Writer w;
		w.init(tmem, "a{sv}")!!;
		w.begin_array("a{sv}")!!;
		put_string(&w, "category", long_name.str_view());
		w.end_array()!!;
		Hints h;
		decode_into(&w, &h);
		assert(h.category.len == notify::MAX_CATEGORY);
	};
}

fn void a_repeated_text_key_keeps_the_last_value() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "a{sv}")!!;
		w.begin_array("a{sv}")!!;
		put_string(&w, "category", "first");
		put_string(&w, "category", "second");
		w.end_array()!!;
		Hints h;
		decode_into(&w, &h);
		assert(h.category == "second");
	};
}

// Hints past MAX_HINTS are skipped: the urgency that comes 65th must not be applied.
fn void the_hint_count_is_capped() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "a{sv}")!!;
		w.begin_array("a{sv}")!!;
		for (int k = 0; k < hints::MAX_HINTS; k++) put_string(&w, "x-filler", "f");
		put_scalar(&w, "urgency", "y", 2);
		w.end_array()!!;
		Hints h;
		decode_into(&w, &h);
		assert(h.urgency == notify::Urgency.NORMAL, "the entry past the cap is not applied");
		assert(h.ignored == 1, "and it is counted");
	};
}

// 3000 sound names of 1000 bytes (3 MB of message): one copy is kept, the rest are skipped and counted.
fn void a_flood_of_text_keeps_one_copy() @test
{
	@pool()
	{
		char[] value = alloc::new_array(tmem, char, 1000);
		for (sz k = 0; k < value.len; k++) value[k] = 'a';
		Writer w;
		w.init(tmem, "a{sv}")!!;
		w.begin_array("a{sv}")!!;
		for (int k = 0; k < 3000; k++) put_string(&w, "sound-name", (String)value);
		w.end_array()!!;
		Hints h;
		decode_into(&w, &h);
		assert(h.sound_name.len == 1000);
		assert(h.ignored == 3000 - hints::MAX_HINTS, "entries past the cap are counted");
	};
}

// Forty valid 512 KiB images (20 MiB): the copies stop at the image budget and the rest are dropped and counted.
fn void image_copies_are_budgeted() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "a{sv}")!!;
		w.begin_array("a{sv}")!!;
		for (int k = 0; k < 40; k++) put_image(&w, "image-data", 4096, 32, 16384, true, 8, 4, 524288, 'p');
		w.end_array()!!;
		Hints h;
		decode_into(&w, &h);
		assert(h.has_image);
		assert(h.copied <= hints::MAX_HINT_BYTES, "copied bytes stay within the budget");
		assert(h.ignored > 0, "images past the budget are dropped and counted");
	};
}

// Every corruption must end as a fault or a valid result, never a crash or a bad read.
fn void fuzzed_hints_never_crash() @test
{
	@pool()
	{
		Writer w;
		w.init(tmem, "a{sv}")!!;
		w.begin_array("a{sv}")!!;
		put_scalar(&w, "urgency", "y", 1);
		put_string(&w, "category", "chat.received");
		put_image(&w, "image-data", 3, 2, 12, true, 8, 4, 24, 'p');
		put_scalar(&w, "value", "i", 7);
		put_string(&w, "x-dunst-stack-tag", "fz");
		w.end_array()!!;
		w.finish()!!;
		String encoded = w.bytes();
		char[] seed    = alloc::new_array(tmem, char, (sz)encoded.len);
		foreach (i, c : encoded) seed[i] = c;
		ulong state = 0x9E3779B97F4A7C15;
		for (int round = 0; round < 20000; round++)
		{
			@pool()
			{
				char[] buffer = alloc::new_array(tmem, char, seed.len);
				foreach (i, c : seed) buffer[i] = c;
				state = xorshift(state);
				int edits = 1 + (int)(state % 4);
				for (int e = 0; e < edits; e++)
				{
					state = xorshift(state);
					buffer[(usz)(state % (ulong)buffer.len)] = (char)(state >> 8);
				}
				state = xorshift(state);
				usz length = buffer.len - (usz)(state % 8);
				decode_corrupt((String)buffer[0:length]);
			};
		}
	};
}

// Random bytes under the same signature: the reader must refuse them or the decoder must accept them.
fn void random_bytes_never_crash() @test
{
	@pool()
	{
		ulong state = 0xD1B54A32D192ED03;
		for (int round = 0; round < 5000; round++)
		{
			@pool()
			{
				usz length    = 1 + (usz)(xorshift(state) % 96);
				char[] buffer = alloc::new_array(tmem, char, (sz)length);
				for (usz k = 0; k < length; k++) buffer[k] = (char)(xorshift(state) >> 24);
				decode_corrupt((String)buffer);
			};
		}
	};
}

// Decode bytes that may be garbage. Refusing them is correct; the test is that nothing traps.
fn void decode_corrupt(String data)
{
	Reader r;
	if (catch r.init(data, "a{sv}")) return;
	Hints h;
	if (catch hints::decode(&r, tmem, &h))
	{
		// A refused message: no hints were kept, which is the right outcome for corrupt input.
	}
}

fn ulong xorshift(ulong state)
{
	ulong s = state;
	s ^= s << 13;
	s ^= s >> 7;
	s ^= s << 17;
	return s;
}