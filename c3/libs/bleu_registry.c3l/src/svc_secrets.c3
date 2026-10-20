<*
 The `secrets` entry of the registry: open adapter, commands and `Spec`.

 Secret values never appear in the state topic. `secrets.read` returns the value
 once, in its reply, to the client that asked for it.
*>
module bleu::registry::svc_secrets;
import bleu::secrets, bleu::registry, bleu::registry::live, bleu::json, bleu::operation, bleu::error;

<* Open the keyring service with its default backend. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	secrets::Options opened = {};
	secrets::Keyring* service = secrets::open(allocator, opened)!;
	return (void*)service;
}

<* The entry named by the `service` and `account` members of the request. *>
fn secrets::Entry? entry_of(registry::Request* request) @private
{
	return { .service = request.params.string("service")!, .account = request.params.string("account")! };
}

<* `secrets.store {service, account, value}`: save a secret. The value is not echoed back. *>
fn void? store(registry::Request* request)
{
	secrets::Keyring* service = (secrets::Keyring*)request.handle;
	secrets::Entry entry = entry_of(request)!;
	String value = request.params.string("value")!;
	Operation{secrets::Entry}* operation = service.store(entry, (char[])value)!;
	defer operation.release();
	registry::await{secrets::Entry}(operation, request.timeout)!;
	return registry::write_ok(request.out);
}

<* `secrets.read {service, account}`: the stored value, as base64 in the reply. *>
fn void? read(registry::Request* request)
{
	secrets::Keyring* service = (secrets::Keyring*)request.handle;
	secrets::Entry entry = entry_of(request)!;
	Operation{secrets::Secret}* operation = service.read(entry)!;
	defer operation.release();
	secrets::Secret secret = registry::await{secrets::Secret}(operation, request.timeout)!;
	return registry::write_value(request.out, "secret", secret);
}

<* `secrets.delete {service, account}`: remove a stored secret. *>
fn void? delete(registry::Request* request)
{
	secrets::Keyring* service = (secrets::Keyring*)request.handle;
	secrets::Entry entry = entry_of(request)!;
	Operation{bool}* operation = service.delete(entry)!;
	defer operation.release();
	registry::await{bool}(operation, request.timeout)!;
	return registry::write_ok(request.out);
}

<*
 The keyring has no change notifications of its own yet, so it cannot stream its state.
 Until it does, the topic is refused with UNSUPPORTED.
*>
fn void? unsupported_watch(void* handle, registry::Tap* tap) @private
{
	return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "secrets state cannot be streamed yet")~;
}

const registry::Command[3] COMMANDS = {
	{ .name = "secrets.store", .summary = "Save a secret: {service, account, value}.", .run = &store },
	{ .name = "secrets.read", .summary = "Read a secret once: {service, account}.", .run = &read },
	{ .name = "secrets.delete", .summary = "Delete a secret: {service, account}.", .run = &delete },
};

const registry::Spec SECRETS = {
	.name = "secrets",
	.summary = "Keyring: stored secrets (Secret Service, Credential Manager, Keychain)",
	.open = &open,
	.close = &live::close{secrets::Keyring, secrets::State, secrets::Cap},
	.state = &live::state{secrets::Keyring, secrets::State, secrets::Cap},
	.state_after = &live::state_after{secrets::Keyring, secrets::State, secrets::Cap},
	.capabilities = &live::capabilities{secrets::Keyring, secrets::State, secrets::Cap},
	.backend = &live::backend{secrets::Keyring, secrets::State, secrets::Cap},
	.watch = &unsupported_watch,
	.commands = COMMANDS[..],
};
