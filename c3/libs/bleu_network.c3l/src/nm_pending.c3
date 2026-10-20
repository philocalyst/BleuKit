// Requests that are still waiting on NetworkManager: connections, disconnects,
// scans and radio switches. Each one completes exactly once, from the device
// state transitions (signals) that arrived after it was made, from a fresh
// read where the state is a plain value (scan, radio), or on its deadline.
module bleu::network::networkmanager @feat(LINUX);
import std::time, bleu::error, bleu::deadline, bleu::network, bleu::network::nm_convert;

<* The request a pending entry is waiting on. *>
enum PendingKind : char
{
	CONNECT,
	DISCONNECT,
	SCAN,
	RADIO,
}

const Duration CONNECT_TIMEOUT    = (Duration)60_000_000; // association, authentication and DHCP
const Duration DISCONNECT_TIMEOUT = (Duration)15_000_000;
const Duration SCAN_TIMEOUT       = (Duration)20_000_000;
const Duration RADIO_TIMEOUT      = (Duration)15_000_000;

<*
 A request in flight. It owns one reference to its operation and every string
 it holds, all in the backend's allocator. `retire_at` releases them.
*>
struct Pending
{
	PendingKind kind;
	ConnectOp* connect; // CONNECT
	SettleOp* settle; // every other kind
	String device; // object path of the Wi-Fi device
	String active; // CONNECT: the active connection NetworkManager made, "" until it answered
	String interface_name; // CONNECT: reported in the operation's value
	char[] ssid; // CONNECT
	bool supplied; // CONNECT: a passphrase was sent with the request
	bool started; // CONNECT: this activation has been seen to begin
	bool target; // RADIO: the wanted value of WirelessEnabled
	long last_scan; // SCAN: LastScan when the request was made
	ulong after; // only transitions newer than this belong to the request
	Deadline deadline;
}

<* A device state change, as its signal reported it, in arrival order. *>
struct Transition
{
	ulong sequence;
	String device;
	uint state;
	uint reason;
}

<* Copy `text` into `allocator`; the empty string is never allocated. *>
fn String own_text(Allocator allocator, String text) @inline
{
	return text.len == 0 ? "" : text.copy(allocator);
}

<* Free a string made by `own_text`. *>
fn void drop_text(Allocator allocator, String text) @inline
{
	if (text.len > 0) alloc::free(allocator, text.ptr);
}

<* Whether a request of this kind is in flight. *>
fn bool has_pending(Backend* b, PendingKind kind)
{
	foreach (&p : b.pending.array_view())
	{
		if (p.kind == kind) return true;
	}
	return false;
}

<*
 Make a request pending. The caller hands over its reference to the operation
 and the strings in `pending`.
*>
fn void add_pending(Backend* b, Pending pending)
{
	pending.after = b.transition_sequence;
	pending.deadline = deadline::after(timeout_of(pending.kind));
	b.pending.push(pending);
}

fn Duration timeout_of(PendingKind kind) @local
{
	switch (kind)
	{
		case CONNECT: return CONNECT_TIMEOUT;
		case DISCONNECT: return DISCONNECT_TIMEOUT;
		case SCAN: return SCAN_TIMEOUT;
		case RADIO: return RADIO_TIMEOUT;
	}
}

<* Remove the request at `index`, releasing its operation and strings. *>
fn void retire_at(Backend* b, sz index)
{
	Pending* p          = b.pending.get_ref(index);
	Allocator allocator = b.allocator;
	drop_text(allocator, p.device);
	drop_text(allocator, p.active);
	drop_text(allocator, p.interface_name);
	if (p.ssid.len > 0) alloc::free(allocator, p.ssid.ptr);
	if (p.connect != null) p.connect.release();
	if (p.settle != null) p.settle.release();
	b.pending.remove_at(index);
}

<* The fault an operation fails with, for a connection failure. *>
fn fault connect_fault(FailureReason reason)
{
	switch (reason)
	{
		case NO_SECRETS:
		case AUTH_REQUIRED:
		case AUTH_REJECTED: return error::AUTH_REQUIRED;
		case SSID_NOT_FOUND: return NOT_FOUND;
		case FailureReason.TIMEOUT: return TIMEOUT;
		case CANCELLED: return error::CANCELLED;
		case DEVICE_UNAVAILABLE: return error::UNAVAILABLE;
		default: return error::BACKEND_FAILURE;
	}
}

<*
 Finish the connection at `index` with a failure. `code` is the NetworkManager
 reason, kept in the error detail with `what` as the message.
*>
fn void fail_connect(Backend* b, sz index, FailureReason reason, uint code, String what)
{
	Pending* p = b.pending.get_ref(index);
	p.connect.fail(error::raise(connect_fault(reason), error::Domain.INTERNAL, (int)code, "%s", what));
	retire_at(b, index);
}

<* The failure class of a device that went down while connecting, given the reason it reported. *>
fn FailureReason failure_while_connecting(uint state, uint reason, bool supplied) @local
{
	FailureReason failure = nm_convert::failure_from_reason(reason);
	if (failure == NO_SECRETS && supplied) return AUTH_REJECTED;
	if (state != nm_convert::DEVICE_STATE_FAILED && failure == UNKNOWN) return DEVICE_UNAVAILABLE;
	return failure;
}

<* Apply one device state to the connection request at `index`. Returns true when it finished. *>
fn bool apply_connect_state(Backend* b, sz index, uint state, uint reason)
{
	Pending* p = b.pending.get_ref(index);
	switch (state)
	{
		case nm_convert::DEVICE_STATE_ACTIVATED:
			b.last_supplied = false;
			p.connect.succeed(
				{
					.ssid = network::make_ssid(p.connect.allocator(), p.ssid),
					.interface_name = p.interface_name.copy(p.connect.allocator()),
				}
			);
			retire_at(b, index);
			return true;
		case nm_convert::DEVICE_STATE_NEED_AUTH:
			// With an agent, NetworkManager asks it for the passphrase (a prompt): the request
			// waits for the answer, and the terminal state decides if the answer never comes.
			if (b.agent_registered) return false;
			if (p.supplied)
			{
				fail_connect(b, index, AUTH_REJECTED, state, "the network rejected the passphrase");
			}
			else
			{
				fail_connect(b, index, AUTH_REQUIRED, state, "the network needs a passphrase");
			}
			return true;
		case nm_convert::DEVICE_STATE_FAILED:
		case nm_convert::DEVICE_STATE_DISCONNECTED:
		case nm_convert::DEVICE_STATE_UNAVAILABLE:
		case nm_convert::DEVICE_STATE_UNMANAGED:

			{
				FailureReason failure = failure_while_connecting(state, reason, p.supplied);
				fail_connect(b, index, failure, reason, "connection failed (NetworkManager state reason)");
				return true;
			}
		default:
			return false;
	}
}

<* Finish the settle request at `index` with `value`. *>
fn void settle_with(Backend* b, sz index, Settled value)
{
	Pending* p = b.pending.get_ref(index);
	p.settle.succeed(value);
	retire_at(b, index);
}

<* Apply every transition that arrived since the last settle, in order, to the requests they concern. *>
fn void apply_transitions(Backend* b)
{
	foreach (t : b.transitions.array_view())
	{
		sz i = 0;
		while (i < b.pending.len())
		{
			Pending* p = b.pending.get_ref(i);
			if (t.sequence <= p.after || p.device != t.device)
			{
				i++;
				continue;
			}
			if (p.kind == CONNECT && !p.started)
			{
				// A terminal state that was already there (the previous attempt's failure, reported late)
				// says nothing about this request. Only its own activation, or a success, counts.
				if (nm_convert::is_activation_state(t.state))
				{
					p.started = true;
				}
				else if (t.state != nm_convert::DEVICE_STATE_ACTIVATED)
				{
					i++;
					continue;
				}
			}
			bool done = false;
			switch (p.kind)
			{
				case CONNECT:
					done = apply_connect_state(b, i, t.state, t.reason);
				case DISCONNECT:
					if (t.state == nm_convert::DEVICE_STATE_DISCONNECTED
						|| t.state == nm_convert::DEVICE_STATE_UNAVAILABLE)
					{
						settle_with(b, i, CHANGED);
						done = true;
					}
				default:
					done = false;
			}
			if (!done) i++;
		}
	}
	foreach (t : b.transitions.array_view()) drop_text(b.allocator, t.device);
	b.transitions.clear();
}

<*
 Complete what the latest read and the transitions allow, and fail what has
 run out of time. Called once per read, on the worker thread.
*>
fn void settle(Backend* b, Reading* r)
{
	apply_transitions(b);
	sz i = 0;
	while (i < b.pending.len())
	{
		Pending* p = b.pending.get_ref(i);
		if (p.deadline.expired())
		{
			if (p.kind == CONNECT)
			{
				if (catch deactivate(b, p.active))
				{
				} // best effort: the timeout below stands either way
				fail_connect(b, i, FailureReason.TIMEOUT, 0, "the connection did not finish in time");
			}
			else
			{
				p.settle.fail(error::raise(TIMEOUT, error::Domain.INTERNAL, 0, "the request did not finish in time"));
				retire_at(b, i);
			}
			continue;
		}
		bool done = false;
		switch (p.kind)
		{
			case SCAN:
				done = r.wifi_found && r.wifi_path == p.device && r.last_scan != p.last_scan;
			case RADIO:
				done = r.radio_enabled == p.target;
			case DISCONNECT:
				done = r.wifi_found && r.wifi_path == p.device
					&& (r.device_state == nm_convert::DEVICE_STATE_DISCONNECTED
						|| r.device_state == nm_convert::DEVICE_STATE_UNAVAILABLE);
			case CONNECT:
				done = false;
		}
		if (done)
		{
			settle_with(b, i, CHANGED);
			continue;
		}
		i++;
	}
}

<* Fail every request still in flight. Used when the service stops. *>
fn void abandon_pending(Backend* b)
{
	while (b.pending.len() > 0)
	{
		Pending* p = b.pending.get_ref(0);
		if (p.kind == CONNECT)
		{
			p.connect.fail(error::CANCELLED);
		}
		else
		{
			p.settle.fail(error::CANCELLED);
		}
		retire_at(b, 0);
	}
}