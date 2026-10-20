<*
 The macOS keychain driver. The login keychain is always present; the probe succeeds.
*>
module bleu::secrets::mac @feat(DARWIN);
import bleu::availability, bleu::secrets, bleu::rt::worker, bleu::service;

<* The backend state: there is none beyond the allocator. *>
struct KeychainBackend
{
	Allocator allocator;
}

<* The login keychain backend. Preferred on macOS. *>
const Driver DRIVER = {
	.info = { "keychain", "macOS login keychain (generic passwords, Security framework)", 10 },
	.id = KEYCHAIN,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	secrets::local_capabilities(
		capabilities,
		"the keychain shows its own access prompt inside the call; Bleu can neither observe nor bound it",
		"the call is made in this process; nothing crosses a bus"
	);
	return alloc::new(allocator, KeychainBackend, { .allocator = allocator });
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

fn void run(void* state, KeyringHub* hub, Host{Command}* host)
{
	secrets::serve_local(state, hub, host, &execute);
}