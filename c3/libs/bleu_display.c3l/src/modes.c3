<*
 Matching a wanted mode against the modes an output advertises. Pure; no platform code.
*>
module bleu::display;
import std::collections::maybe;

<*
 Largest difference, in millihertz, at which two refresh rates count as the same mode. 100 mHz
 (0.1 Hz) keeps 59.94 Hz and 60 Hz apart, and still matches a 59940 mHz request against a
 driver that reports 59.94 as 59940 with rounding noise.
*>
const RefreshMilliHz DEFAULT_REFRESH_TOLERANCE = 100;

<* True when two refresh rates differ by no more than `tolerance` millihertz. *>
fn bool refresh_matches(RefreshMilliHz a, RefreshMilliHz b, RefreshMilliHz tolerance) @inline
{
	return a > b ? a - b <= tolerance : b - a <= tolerance;
}

<*
 Index of the advertised mode that best fits `wanted`. The size must match exactly. A wanted
 refresh of 0 selects the highest refresh rate of that size; otherwise the mode whose refresh is
 closest to the wanted one wins, provided it is within `tolerance`. Empty when nothing fits.
*>
fn Maybe{usz} find_mode(Mode[] modes, Mode wanted, RefreshMilliHz tolerance)
{
	bool found = false;
	usz best = 0;
	for (usz i = 0; i < modes.len; i++) {
		Mode candidate = modes[i];
		if (candidate.width != wanted.width || candidate.height != wanted.height) continue;
		if (wanted.refresh == 0) {
			if (!found || candidate.refresh > modes[best].refresh) {
				found = true;
				best = i;
			}
			continue;
		}
		if (!refresh_matches(candidate.refresh, wanted.refresh, tolerance)) continue;
		if (!found || closer(candidate.refresh, modes[best].refresh, wanted.refresh)) {
			found = true;
			best = i;
		}
	}
	if (!found) return { };
	return maybe::value(best);
}

// True when `a` is strictly closer to `target` than `b` is.
fn bool closer(RefreshMilliHz a, RefreshMilliHz b, RefreshMilliHz target) @private
{
	RefreshMilliHz da = a > target ? a - target : target - a;
	RefreshMilliHz db = b > target ? b - target : target - b;
	return da < db;
}
