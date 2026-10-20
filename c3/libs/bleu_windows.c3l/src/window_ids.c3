<*
 Window ids of the macOS backend: a CGWindowID is written as decimal digits. Pure, so it is
 tested on every host.
*>
module bleu::windows::window_ids;
import bleu::error;

// The window number of a window id: decimal digits only.
fn long? number_of(String id)
{
	if (id.len == 0 || id.len > 18) return error::raise(
		error::INVALID_ARGUMENT,
		error::Domain.INTERNAL,
		0,
		"'%s' is not a window id",
		id
	)~;
	long value = 0;
	foreach (c : id)
	{
		if (c < '0' || c > '9') return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"'%s' is not a window id",
			id
		)~;
		value = value * 10 + (long)(c - '0');
	}
	return value;
}