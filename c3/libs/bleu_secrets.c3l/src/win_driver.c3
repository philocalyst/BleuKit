<*
 The Windows Credential Manager driver. Always present on Windows, so the probe
 succeeds; the state has nothing to hold.
*>
module bleu::secrets::win @feat(WIN32);
import bleu::availability, bleu::secrets, bleu::rt::worker, bleu::service;

<* The backend state: there is none beyond the allocator. *>
struct WinBackend
{
	Allocator allocator;
}

<* The Credential Manager backend. Preferred on Windows. *>
const Driver DRIVER = {
	.info = {
		"credential-manager",
		"Windows Credential Manager (generic credentials, local machine persistence)",
		10
	},
	.id = CREDENTIAL_MANAGER,
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
		"Credential Manager has no lock to release",
		"the call is made in this process; nothing crosses a bus"
	);
	return alloc::new(allocator, WinBackend, { .allocator = allocator });
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

fn void run(void* state, KeyringHub* hub, Host{Command}* host)
{
	secrets::serve_local(state, hub, host, &execute);
}