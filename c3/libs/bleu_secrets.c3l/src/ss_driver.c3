<*
 The Secret Service driver: probes the keyring at open time, and hands the
 worker its backend state.

 Sources: the bus name and interfaces are in `ss_wire.c3`; the activation of a
 service that is not running is `StartServiceByName` (org.freedesktop.DBus,
 "Starting services").
*>
module bleu::secrets::ss @feat(LINUX);
import std::time;
import std::atomic;
import bleu::availability, bleu::error, bleu::dbus::connection, bleu::secrets;

<* The Secret Service backend. Preferred on Linux: it is the standard keyring API. *>
const Driver DRIVER = {
	.info = { "secret-service", "freedesktop Secret Service (org.freedesktop.secrets) over D-Bus", 10 },
	.id = SECRET_SERVICE,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// The probe is cheap and cannot tell whether the keyring is there; `create` does that.
fn bool probe(Options* options) => true;

<*
 Connect, make sure the keyring answers (starting it when the bus can), and
 find out whether the encrypted session is offered. Runs on a connection of its
 own, owned by the caller's thread.

 @return? error::UNAVAILABLE : "No bus, or no keyring service on it"
*>
fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	SsBackend trial = {
		.allocator = allocator,
		.bus_address = options.bus_address,
		.prompt_timeout = options.prompt_timeout,
		.allow_plain = options.allow_plain_transport,
	};
	trial.bus.init(allocator);
	defer trial.bus.free();
	defer drop(&trial);
	if (catch err = ensure_bus(&trial)) return err~;
	if (!trial.bus.name_has_owner(BUS_NAME)!)
	{
		if (catch trial.bus.start_service_by_name(BUS_NAME)) return error::UNAVAILABLE~;
		if (!trial.bus.name_has_owner(BUS_NAME)!) return error::UNAVAILABLE~;
	}
	capabilities.init(availability::YES);
	if (catch err = open_encrypted(&trial))
	{
		if (!refused_algorithm()) return err~;
		capabilities.values[Cap.ENCRYPTED_TRANSPORT.ordinal] = availability::no(UNSUPPORTED_BACKEND, "the keyring refuses the encrypted session; secrets cross the bus unencrypted only when Options.allow_plain_transport is set");
	}
	SsBackend* self = alloc::new(allocator, SsBackend, {
		.allocator = allocator,
		.bus_address = options.bus_address.len > 0 ? options.bus_address.copy(allocator) : "",
		.prompt_timeout = options.prompt_timeout,
		.allow_plain = options.allow_plain_transport,
	});
	return self;
}

<* Free the state. The connection was released by the worker when it stopped. *>
fn void destroy(Allocator allocator, void* state)
{
	SsBackend* b = (SsBackend*)state;
	if (b.bus_address.len > 0) alloc::free(allocator, b.bus_address.ptr);
	alloc::free(allocator, b);
}
