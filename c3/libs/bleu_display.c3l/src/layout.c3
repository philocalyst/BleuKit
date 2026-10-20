<*
 Layout rules shared by every platform: the rectangles of the enabled outputs must not overlap,
 must form one connected desktop (the pointer can reach every output), and a layout can be moved
 so that a chosen output sits at the origin. Pure; no platform code.
*>
module bleu::display;
import bleu::error;

<* The most outputs one layout is checked for. Larger layouts are refused rather than guessed at. *>
const sz MAX_LAYOUT_OUTPUTS = 64;

<* A rectangle on the desktop in logical pixels. *>
struct Rect
{
	int x;
	int y;
	int width;
	int height;
}

<* A translation of the desktop origin. *>
struct Offset
{
	int x;
	int y;
}

<* True when the two rectangles share some area. Touching edges do not count. *>
fn bool Rect.overlaps(self, Rect other) @inline
{
	return self.x < other.x + other.width && other.x < self.x + self.width
		&& self.y < other.y + other.height && other.y < self.y + self.height;
}

<* True when the two rectangles share an edge of positive length, so the pointer crosses between them. *>
fn bool Rect.touches(self, Rect other) @inline
{
	bool side_by_side = self.x + self.width == other.x || other.x + other.width == self.x;
	bool stacked      = self.y + self.height == other.y || other.y + other.height == self.y;
	bool rows_meet    = self.y < other.y + other.height && other.y < self.y + self.height;
	bool columns_meet = self.x < other.x + other.width && other.x < self.x + self.width;
	return (side_by_side && rows_meet) || (stacked && columns_meet);
}

<* The rectangle moved by `by`. *>
fn Rect Rect.shifted(self, Offset by) @inline => { .x = self.x + by.x, .y = self.y + by.y, .width = self.width, .height = self.height };

<*
 Check that the enabled outputs form one desktop: at least one, no two overlapping, and every one
 reachable from the others through edges of positive length. A gap is not refused by itself;
 an output that the pointer cannot reach is.

 @param rects : "The rectangles of the enabled outputs, in logical pixels"
 @return? error::INVALID_ARGUMENT : "No output is enabled, two overlap, an output is cut off, or there are too many"
*>
fn void? validate_layout(Rect[] rects)
{
	if (rects.len == 0) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "no output is enabled")~;
	if (rects.len > MAX_LAYOUT_OUTPUTS) {
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "more than %d outputs", (int)MAX_LAYOUT_OUTPUTS)~;
	}
	for (sz i = 0; i < rects.len; i++) {
		for (sz j = i + 1; j < rects.len; j++) {
			if (rects[i].overlaps(rects[j])) {
				return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "outputs %d and %d overlap", (int)i, (int)j)~;
			}
		}
	}
	bool[MAX_LAYOUT_OUTPUTS] reached = { };
	reached[0] = true;
	bool grew = true;
	while (grew) {
		grew = false;
		for (sz i = 0; i < rects.len; i++) {
			if (reached[i]) continue;
			for (sz j = 0; j < rects.len; j++) {
				if (reached[j] && rects[i].touches(rects[j])) {
					reached[i] = true;
					grew = true;
					break;
				}
			}
		}
	}
	for (sz i = 0; i < rects.len; i++) {
		if (!reached[i]) {
			return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "output %d is cut off from the rest of the layout", (int)i)~;
		}
	}
}

<*
 The translation that moves the layout's origin onto `anchor` (an index into `rects`), or onto
 the top-left corner of the bounding box when `anchor` is negative. Use the anchor where the OS
 pins the primary output at (0, 0); use the bounding box where a compositor allows any origin.
*>
fn Offset origin_offset(Rect[] rects, sz anchor)
{
	if (rects.len == 0) return { };
	if (anchor >= 0 && anchor < rects.len) return { .x = -rects[anchor].x, .y = -rects[anchor].y };
	int min_x = rects[0].x;
	int min_y = rects[0].y;
	foreach (rect : rects) {
		if (rect.x < min_x) min_x = rect.x;
		if (rect.y < min_y) min_y = rect.y;
	}
	return { .x = -min_x, .y = -min_y };
}
