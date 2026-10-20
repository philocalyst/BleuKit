<*
 Reading systemd-localed's configured keyboard layouts from its `X11Layout` and `X11Variant` properties.

 Both properties are comma-separated lists, and the variant list is aligned with the layout list: the
 field at position i of each names layout i ("us,de" with ",nodeadkeys" is us and de(nodeadkeys)). Source:
 systemd man page org.freedesktop.locale1 (https://www.freedesktop.org/software/systemd/man/latest/org.freedesktop.locale1.html),
 which lists X11Layout and X11Variant as read-only strings; systemd src/locale/localectl.c, which reads them with
 the same names.
*>
module bleu::input::locale1_convert;
import bleu::input, bleu::input::names;

<* The `index`th comma-separated field of `list`, "" when there are fewer. Empty fields keep their place. *>
fn String field_at(String list, sz index)
{
	sz field = 0;
	sz start = 0;
	for (sz i = 0; i <= list.len; i++)
	{
		if (i < list.len && list[i] != ',') continue;
		if (field == index) return list[start:i - start];
		field++;
		start = i + 1;
	}
	return "";
}

<* The number of comma-separated fields in `list`: 0 for "", otherwise one more than its commas. *>
fn sz field_count(String list)
{
	if (list.len == 0) return 0;
	sz count = 1;
	for (sz i = 0; i < list.len; i++)
	{
		if (list[i] == ',') count++;
	}
	return count;
}

<*
 The configured layouts: one per non-empty layout field, with the variant at the same position.

 Callers hold a `@pool()` (the names are formatted in tmem). The result is allocated in `allocator`.
*>
fn Layout[] layouts_from(String layouts, String variants, Allocator allocator)
{
	sz count = field_count(layouts);
	sz kept = 0;
	for (sz i = 0; i < count; i++)
	{
		if (field_at(layouts, i).len > 0) kept++;
	}
	Layout[] result = alloc::new_array(allocator, Layout, kept);
	sz out = 0;
	for (sz i = 0; i < count; i++)
	{
		String layout = field_at(layouts, i);
		if (layout.len == 0) continue;
		result[out++] = names::layout_from_parts(layout, field_at(variants, i), allocator);
	}
	return result;
}
