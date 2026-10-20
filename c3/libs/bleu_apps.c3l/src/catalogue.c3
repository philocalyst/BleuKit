module bleu::apps;
import bleu::equal, std::collections::list;

<*
 Order of the catalogue: by name, ASCII case-insensitively, then by id. Two
 backends that find the same apps therefore publish the same list.

 @return "true when `a` sorts before `b`"
*>
fn bool app_before(App* a, App* b)
{
	sz order = compare_folded(a.name, b.name);
	if (order != 0) return order < 0;
	return compare_folded(a.id, b.id) < 0;
}

<* Sort `apps` in place with `app_before`. Insertion sort: catalogues are a few hundred apps. *>
fn void sort_catalogue(App[] apps)
{
	for (usz i = 1; i < apps.len; i++)
	{
		App current = apps[i];
		usz j = i;
		while (j > 0 && app_before(&current, &apps[j - 1]))
		{
			apps[j] = apps[j - 1];
			j--;
		}
		apps[j] = current;
	}
}

<*
 Compare two strings ASCII case-insensitively. Negative when `a` sorts first.
*>
fn sz compare_folded(String a, String b) @local
{
	sz n = min(a.len, b.len);
	for (sz i = 0; i < n; i++)
	{
		sz x = fold(a[i]);
		sz y = fold(b[i]);
		if (x != y) return x - y;
	}
	return a.len - b.len;
}

<*
 The events that turn `old` into `new`, matched by `id`: an id only in `new` was
 added, only in `old` was removed, in both with different content was changed.
 Events come in catalogue order of the app they concern, removals first.

 @param [&inout] out : "Receives the events; not cleared"
*>
fn void diff_catalogue(State* old, State* new, List{Event}* out)
{
	foreach (app : old.apps)
	{
		if (!find_by_id(new, app.id)) out.push({ .kind = APP_REMOVED, .app_id = app.id });
	}
	foreach (app : new.apps)
	{
		App* before = find_by_id(old, app.id);
		if (!before)
		{
			out.push({ .kind = APP_ADDED, .app_id = app.id });
		}
		else if (!equal::deep(*before, app))
		{
			out.push({ .kind = APP_CHANGED, .app_id = app.id });
		}
	}
}

<* The app with this id, or null. The catalogue is small, so a scan is what it costs. *>
fn App* find_by_id(State* state, String id)
{
	foreach (&app : state.apps)
	{
		if (app.id == id) return app;
	}
	return null;
}
