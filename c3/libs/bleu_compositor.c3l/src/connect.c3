<*
 Open the client for the compositor a `Detection` names.
*>
module bleu::compositor::connect @feat(POSIX);
import bleu::compositor, bleu::compositor::backend, bleu::compositor::hyprland_io, bleu::compositor::sway_io, bleu::compositor::niri_io, bleu::error;

<*
 Connect to the compositor `detection` describes. The returned backend owns its
 sockets until `close` is called on it.

 @param allocator : "Long-lived allocator for the backend (not tmem)"
 @return? error::UNAVAILABLE : "No compositor was detected, or its socket is not set"
 @return? error::UNSUPPORTED : "The compositor has no IPC client in this library (river, dwl)"
 @return? error::PERMISSION_DENIED, error::BACKEND_FAILURE, error::PROTOCOL : "Connecting or subscribing failed"
*>
fn backend::Backend? open(Allocator allocator, compositor::Detection detection)
{
	switch (detection.kind)
	{
		case compositor::Kind.HYPRLAND: return hyprland_io::open(allocator, detection);
		case compositor::Kind.SWAY: return sway_io::open(allocator, detection, compositor::Kind.SWAY);
		case compositor::Kind.I3: return sway_io::open(allocator, detection, compositor::Kind.I3);
		case compositor::Kind.NIRI: return niri_io::open(allocator, detection);
		case compositor::Kind.RIVER:
		case compositor::Kind.DWL: return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "%s has no IPC client here", detection.kind == compositor::Kind.RIVER ? "river" : "dwl")~;
		case compositor::Kind.NONE: return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "%s", detection.reason)~;
	}
}
