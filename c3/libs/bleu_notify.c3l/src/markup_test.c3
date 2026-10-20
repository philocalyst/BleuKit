module bleu::notify::markup_test;
import std::collections::list, bleu::notify, bleu::notify::markup;

// The runs of `body` as one string per run, for compact assertions: "text|flags|link".
fn String render(Allocator allocator, String body)
{
	notify::Span[] runs = markup::parse(allocator, body);
	DString out;
	out.init(allocator);
	foreach (run : runs)
	{
		out.append_string(run.text);
		out.append_char('|');
		if (run.bold) out.append_char('b');
		if (run.italic) out.append_char('i');
		if (run.underline) out.append_char('u');
		out.append_char('|');
		out.append_string(run.link);
		out.append_char(';');
	}
	return out.str_view();
}

fn void plain_text_is_one_run() @test
{
	@pool()
	{
		assert(render(tmem, "hello world") == "hello world||;");
		assert(render(tmem, "") == "");
	};
}

fn void styles_nest_and_close() @test
{
	@pool()
	{
		assert(render(tmem, "a<b>b<i>c</i>d</b>e") == "a||;b|b|;c|bi|;d|b|;e||;");
		assert(render(tmem, "<u>x</u>") == "x|u|;");
	};
}

fn void tags_are_case_insensitive() @test
{
	@pool()
	{
		assert(render(tmem, "<B>x</b>") == "x|b|;");
	};
}

fn void links_carry_their_href() @test
{
	@pool()
	{
		assert(render(tmem, `see <a href="file:///tmp/x">here</a>.`) == "see ||;here||file:///tmp/x;.||;");
		assert(render(tmem, "<a href='https://e.org/a?b=c'>y</a>") == "y||https://e.org/a?b=c;");
	};
}

fn void a_link_without_href_is_plain() @test
{
	@pool()
	{
		assert(render(tmem, "<a>z</a>") == "z||;");
	};
}

fn void a_href_with_control_characters_is_dropped() @test
{
	@pool()
	{
		assert(render(tmem, "<a href=\"a\nb\">q</a>") == "q||;");
	};
}

fn void entities_are_decoded() @test
{
	@pool()
	{
		assert(render(tmem, "a &amp; b &lt;t&gt; &quot;q&quot; &apos;s&apos; &copy;") == "a & b <t> \"q\" 's' &copy;||;");
	};
}

fn void unknown_tags_go_and_their_text_stays() @test
{
	@pool()
	{
		assert(render(tmem, "<span class=\"x\">x</span><br/>y") == "xy||;");
		assert(render(tmem, "<script>1</script>") == "1||;");
	};
}

fn void an_image_contributes_its_alt_text() @test
{
	@pool()
	{
		assert(render(tmem, `pre<img src="a.png" alt="pic &amp; co">post`) == "prepic & copost||;");
		assert(render(tmem, `<img src="a.png">`) == "");
	};
}

fn void unclosed_and_stray_tags_are_tolerated() @test
{
	@pool()
	{
		assert(render(tmem, "<b>bold") == "bold|b|;");
		assert(render(tmem, "x</i>y") == "xy||;");
		assert(render(tmem, "<b>a</i>b") == "ab|b|;");
	};
}

fn void a_lone_less_than_is_text() @test
{
	@pool()
	{
		assert(render(tmem, "1 < 2 and 3<4") == "1 < 2 and 3<4||;");
		// An unfinished tag has no `>`, so it is text too.
		assert(render(tmem, "<a href=\"x") == "<a href=\"x||;");
	};
}

fn void deep_nesting_is_bounded() @test
{
	@pool()
	{
		DString body;
		body.init(tmem);
		for (int k = 0; k < 40; k++) body.append_string("<b>");
		body.append_string("deep");
		String out = render(tmem, body.str_view());
		assert(out == "deep|b|;");
	};
}

fn void run_count_is_bounded() @test
{
	@pool()
	{
		DString body;
		body.init(tmem);
		for (int k = 0; k < 400; k++) body.append_string("<b>x</b>y");
		notify::Span[] runs = markup::parse(tmem, body.str_view());
		assert(runs.len <= (sz)notify::MAX_SPANS);
		assert(runs.len == (sz)notify::MAX_SPANS);
	};
}

fn void body_length_is_bounded() @test
{
	@pool()
	{
		DString body;
		body.init(tmem);
		for (int k = 0; k < 10000; k++) body.append_char('a');
		notify::Span[] runs = markup::parse(tmem, body.str_view());
		usz total = 0;
		foreach (run : runs) total += run.text.len;
		assert(total == notify::MAX_BODY);
	};
}
