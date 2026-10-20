<*
 The Windows build of the socket client. The daemon speaks over Unix sockets,
 which this build does not have, so socket commands refuse with UNSUPPORTED.
 `--embedded` works on every platform.
*>
module bleuctl::client @feat(WIN32);
import bleu::error, bleuctl::options;

<*
 Refuse: there are no Unix domain sockets in this build.

 @return? error::UNSUPPORTED : "Talking to bleud needs Unix domain sockets; use --embedded"
*>
fn int? run(options::Options opts)
{
	return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "talking to bleud needs Unix domain sockets; use --embedded")~;
}
