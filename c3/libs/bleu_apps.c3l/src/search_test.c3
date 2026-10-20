module bleu::apps;
import std::collections::list;

fn State sample_state() @local
{
	static App[3] apps = {
		{
			.id = "firefox.desktop",
			.name = "Firefox",
			.generic_name = "Web Browser",
			.comment = "Browse the web",
			.keywords = { "internet", "www" },
			.launch = EXEC,
			.target = "/usr/bin/firefox %u"
		},
		{
			.id = "xterm.desktop",
			.name = "XTerm",
			.generic_name = "Terminal Emulator",
			.comment = "Terminal window",
			.launch = EXEC,
			.target = "xterm"
		},
		{
			.id = "files.desktop",
			.name = "Files",
			.generic_name = "File Manager",
			.comment = "Open the file browser",
			.launch = EXEC,
			.target = "nautilus --new-window"
		},
	};
	return { .apps = apps[..] };
}

fn void empty_query_lists_everything() @test
{
	State state      = sample_state();
	SearchHit[] hits = rank(&state, "", null, null, mem);
	defer alloc::free(mem, hits.ptr);
	assert(hits.len == 3);
	assert(hits[0].index == 0 && hits[1].index == 1 && hits[2].index == 2);
}

fn void name_prefix_outranks_comment_match() @test
{
	State state      = sample_state();
	SearchHit[] hits = rank(&state, "fire", null, null, mem);
	defer alloc::free(mem, hits.ptr);
	// Firefox by name prefix; Files only fuzzily, through "file browser" in its comment.
	assert(hits.len == 2, "Firefox and the Files comment");
	assert(hits[0].index == 0 && hits[0].score >= SCORE_PREFIX * WEIGHT_NAME / PERCENT);
	assert(hits[1].index == 2 && hits[1].score < hits[0].score);
}

fn void generic_name_and_keywords_are_searched() @test
{
	State state     = sample_state();
	SearchHit[] web = rank(&state, "web", null, null, mem);
	defer alloc::free(mem, web.ptr);
	assert(web.len == 1 && web[0].index == 0, "generic name 'Web Browser' and comment match");
	SearchHit[] www = rank(&state, "www", null, null, mem);
	defer alloc::free(mem, www.ptr);
	assert(www.len == 1 && www[0].index == 0, "keyword match");
}

fn void program_name_is_searched() @test
{
	State state      = sample_state();
	SearchHit[] hits = rank(&state, "nautilus", null, null, mem);
	defer alloc::free(mem, hits.ptr);
	assert(hits.len == 1 && hits[0].index == 2, "basename of the first word of Exec");
}

fn void every_word_must_match() @test
{
	State state      = sample_state();
	SearchHit[] hits = rank(&state, "web zzz", null, null, mem);
	defer alloc::free(mem, hits.ptr);
	assert(hits.len == 0);
	SearchHit[] both = rank(&state, "fire web", null, null, mem);
	defer alloc::free(mem, both.ptr);
	assert(both.len == 1 && both[0].index == 0);
}

fn void fuzzy_matches_letters_in_order() @test
{
	assert(match_score("Firefox", "ffx") > 0, "letters in order");
	assert(match_score("Firefox", "xf") == 0, "out of order");
	assert(match_score("Firefox", "fire") == SCORE_PREFIX);
	assert(match_score("Visual Studio Code", "studio") == SCORE_WORD);
	assert(match_score("Visual Studio Code", "udio") == SCORE_SUBSTRING);
	assert(match_score("Firefox", "FIREFOX") == SCORE_EXACT, "case-insensitive");
}

fn int prefer_xterm(void* context, App* app)
{
	return app.id == "xterm.desktop" ? 500 : 0;
}

fn void ranker_bonus_breaks_ties_and_reorders() @test
{
	State state       = sample_state();
	// "t" matches XTerm (name prefix? no: word start) and others by substring; the bonus must decide.
	SearchHit[] plain = rank(&state, "e", null, null, mem);
	defer alloc::free(mem, plain.ptr);
	SearchHit[] boosted = rank(&state, "e", &prefer_xterm, null, mem);
	defer alloc::free(mem, boosted.ptr);
	assert(boosted.len == plain.len);
	assert(boosted[0].index == 1, "the bonus lifts XTerm to the top");
}

fn void ties_keep_catalogue_order() @test
{
	App[2] apps      = { { .id = "b.desktop", .name = "Same" }, { .id = "a.desktop", .name = "Same" } };
	State state      = { .apps = apps[..] };
	SearchHit[] hits = rank(&state, "same", null, null, mem);
	defer alloc::free(mem, hits.ptr);
	assert(hits.len == 2 && hits[0].index == 0 && hits[1].index == 1);
}

fn void catalogue_order_is_name_then_id() @test
{
	App[3] apps = {
		{ .id = "z.desktop", .name = "beta" },
		{ .id = "y.desktop", .name = "Alpha" },
		{ .id = "a.desktop", .name = "beta" }
	};
	sort_catalogue(apps[..]);
	assert(apps[0].id == "y.desktop" && apps[1].id == "a.desktop" && apps[2].id == "z.desktop");
}

fn void diff_reports_added_removed_and_changed() @test
{
	App[2] old_apps = { { .id = "a.desktop", .name = "A" }, { .id = "b.desktop", .name = "B" } };
	App[2] new_apps = { { .id = "a.desktop", .name = "A2" }, { .id = "c.desktop", .name = "C" } };
	State old_state = { .apps = old_apps[..] };
	State new_state = { .apps = new_apps[..] };
	List{Event} events;
	events.tinit();
	diff_catalogue(&old_state, &new_state, &events);
	assert(events.size == 3);
	assert(events[0].kind == APP_REMOVED && events[0].app_id == "b.desktop");
	assert(events[1].kind == APP_CHANGED && events[1].app_id == "a.desktop");
	assert(events[2].kind == APP_ADDED && events[2].app_id == "c.desktop");
}