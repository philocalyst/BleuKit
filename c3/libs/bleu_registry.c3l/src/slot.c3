<*
 One service of the registry: opened, or refused with the reason it could not open.

 A slot is created in place and must not move while it is open, because a watch
 keeps the address of its tap.
*>
module bleu::registry;
import std::time, bleu::error, bleu::json;

<*
 One service's place in the registry: open, or refused with the reason it could
 not open. The reason is kept so that every later request can say why.
*>
struct Slot
{
	Spec* spec;
	Allocator allocator;
	void* handle; // null unless the service is open
	bool attempted; // `open` was called (whether it succeeded or not)
	fault failure; // why it did not open; the excuse is kept so the status survives
	String failure_message; // the message of `failure`, owned by `allocator`
	Tap tap;
}

<*
 Describe the fault now in `error::last()` as the message of a refused service.

 @return "The message, copied into `allocator`"
*>
fn String describe_failure(fault failure, Allocator allocator)
{
	String message = error::last().message();
	// A backend that failed without a message still gets a reason: its status name.
	if (!message.len) message = "no backend works here";
	return message.copy(allocator);
}

<*
 Open the service `spec` names, once. A failure is kept in the slot and returned.

 @param allocator : "Owner of the service and its snapshots; released by `close`"
 @return? error::UNAVAILABLE : "The service has no backend that works here"
*>
fn void? Slot.open(&self, Spec* spec, Allocator allocator, OpenOptions options)
{
	self.spec = spec;
	self.allocator = allocator;
	self.attempted = true;
	void*? opened = spec.open(allocator, options);
	if (catch err = opened)
	{
		self.failure = err;
		self.failure_message = describe_failure(err, allocator);
		return err~;
	}
	self.handle = opened;
}

<* Stop the service and release it. A slot that is not open does nothing. *>
fn void Slot.close(&self)
{
	if (!self.handle) return;
	self.spec.close(self.handle);
	self.handle = null;
}

<*
 The fault that a request to a closed service raises: the status and message of
 the reason it did not open.
*>
fn void? Slot.require_open(&self)
{
	if (self.handle) return;
	if (!self.failure_message.len)
	{
		return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "service %s is not open", self.spec.name)~;
	}
	return error::raise(self.failure, error::Domain.INTERNAL, 0, "%s", self.failure_message)~;
}

<* Write the latest state object of an open service. *>
fn void? Slot.write_state(&self, json::JsonWriter* out)
{
	self.require_open()!;
	return self.spec.state(self.handle, out);
}

<* Write the state object after a newer generation than `seen`, or fail with TIMEOUT. *>
fn void? Slot.write_state_after(&self, ulong seen, Duration timeout, json::JsonWriter* out)
{
	self.require_open()!;
	return self.spec.state_after(self.handle, seen, timeout, out);
}

<* Write the capabilities array of an open service. *>
fn void? Slot.write_capabilities(&self, json::JsonWriter* out)
{
	self.require_open()!;
	return self.spec.capabilities(self.handle, out);
}

<* The backend in use, or the reason the service is not open. *>
fn String? Slot.backend(&self)
{
	self.require_open()!;
	return self.spec.backend(self.handle);
}

<*
 Deliver every state of an open service to `sink`, starting with the current one.
 The watch lasts until `close`.
*>
fn void? Slot.watch(&self, Sink sink, void* context)
{
	self.require_open()!;
	self.tap = { .sink = sink, .context = context };
	return self.spec.watch(self.handle, &self.tap);
}

<*
 Run the command `method` with `params`, writing its result object into `out`.
 The command waits for its operation for its own timeout, or `DEFAULT_TIMEOUT`.

 @return? NOT_FOUND : "No command of this service has that name"
 @return? error::UNAVAILABLE : "The service is not open; the message says why"
*>
fn void? Slot.call(&self, String method, json::read::Params params, json::JsonWriter* out)
{
	Command* command = find_command(self.spec, method);
	if (!command) return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "unknown method: %s", method)~;
	self.require_open()!;
	Duration timeout = command.timeout == time::DURATION_ZERO ? DEFAULT_TIMEOUT : command.timeout;
	Request request = { .handle = self.handle, .params = params, .out = out, .timeout = timeout };
	return command.run(&request);
}

<*
 Write one summary object for `--list` and the `services` method:
 `{"name", "summary", "open", "backend"}` when open, or `{..., "open": false, "reason"}`.
*>
fn void? Slot.write_summary(&self, json::JsonWriter* out)
{
	out.begin_object()!;
	out.key("name")!;
	out.put_string(self.spec.name)!;
	out.key("summary")!;
	out.put_string(self.spec.summary)!;
	out.key("open")!;
	out.put_bool(self.handle != null)!;
	if (self.handle)
	{
		out.key("backend")!;
		out.put_string(self.spec.backend(self.handle))!;
	}
	else
	{
		out.key("reason")!;
		out.put_string(self.attempted ? self.failure_message : "not selected")!;
	}
	return out.end_object();
}

<*
 The table index of the service named `name`.

 @return? NOT_FOUND : "No registered service has that name"
*>
fn usz? index_of_service(String name)
{
	for (usz i = 0; i < SERVICE_COUNT; i++)
	{
		if (SERVICES[i].name == name) return i;
	}
	return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "not a service: %s", name)~;
}

<*
 Open the services named in `names`, a comma-separated list; "" means every service.
 Each named service is attempted once. A service that fails stays closed and keeps
 its reason in its slot, so one failure does not stop the others.

 @param slots : "One slot per registered service, in table order (`SERVICE_COUNT` of them); each gets its spec"
 @return? error::INVALID_ARGUMENT : "A name in the list is not a registered service"
*>
fn void? open_selected(Slot[] slots, String names, Allocator allocator, OpenOptions options)
{
	// Every slot knows its service, opened or not, so that every request can name it.
	for (usz i = 0; i < SERVICE_COUNT; i++) slots[i].spec = SERVICES[i];
	bool[SERVICE_COUNT] wanted = { };
	if (names.len == 0)
	{
		for (usz i = 0; i < SERVICE_COUNT; i++) wanted[i] = true;
	}
	else
	{
		usz start = 0;
		while (start <= names.len)
		{
			usz end = start;
			while (end < names.len && names[end] != ',') end++;
			usz index = index_of_service(names[start : end - start])!;
			wanted[index] = true;
			start = end + 1;
		}
	}
	for (usz i = 0; i < SERVICE_COUNT; i++)
	{
		if (!wanted[i]) continue;
		// The failure is kept in the slot for every later request to report; it is not raised here.
		if (catch slots[i].open(SERVICES[i], allocator, options)) {}
	}
}

<* The command of `spec` named `method`, or null. *>
fn Command* find_command(Spec* spec, String method)
{
	foreach (&command : spec.commands)
	{
		if (command.name == method) return command;
	}
	return null;
}
