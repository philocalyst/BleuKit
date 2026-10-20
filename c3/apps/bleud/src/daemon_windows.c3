<*
 The Windows build of the daemon. `bleu_ipc` speaks over Unix sockets, which
 Windows does not provide here, so `serve` refuses with UNSUPPORTED. Every other
 command of `bleud` (`--list`, `--services`) still works.
*>
module bleud::daemon @feat(WIN32);
import bleu::error, bleu::registry;

<*
 Refuse to serve: the IPC protocol needs Unix sockets, and this build has none.

 @return? error::UNSUPPORTED : "Serving needs Unix domain sockets, which this build does not have"
*>
fn int? serve(registry::Slot[] slots, String socket_path)
{
	return error::raise(
		error::UNSUPPORTED,
		error::Domain.INTERNAL,
		0,
		"bleud serve needs Unix domain sockets; this build has none"
	)~;
}