<*
 The `evdev` module: DMS's caps-lock state (`core/internal/server/evdev/`, `models.go`:
 `State{available, capsLock}`; `handlers.go`: `evdev.getState`, the only method).

 Bleu has no source for it. `bleu_input` reports keyboard layouts; its README cuts the
 lock keys (caps, num, scroll) from v1. So `evdev.getState` is refused, and the
 `evdev` capability is not advertised. The stream form (`evdev` in `subscribe`) has no
 topic here either. Deviations: docs/DMSD.md.
*>
module dmsd::evdev_mod;
import bleu::ipc, dmsd::contract, dmsd::replies;

const String GET_STATE_REASON = "not supported: bleu_input reports keyboard layouts only; the caps lock state is not read";

// The refused methods. One row: DMS's only evdev method.
const replies::Refusal[1] REFUSALS = {
	{ .method = "evdev.getState", .text = GET_STATE_REASON },
};

// The module's descriptor for `main`. It has no state, no topic and no capability.
const contract::Module DESCRIPTOR = {
	.name = "evdev",
	.start = &start,
	.stop = &stop,
};

fn contract::Module descriptor() => DESCRIPTOR;

<* Register the refused method. Nothing can fail here: the backend is not needed. *>
fn bool start(contract::Context* context, contract::Module* self)
{
	replies::register_all(context.server, REFUSALS[..], &handle_refused)!!;
	return true;
}

// Nothing was started, so there is nothing to stop.
fn void stop(contract::Context* context, contract::Module* self)
{
}

fn void handle_refused(void* context, ipc::Call* call)
{
	replies::answer(REFUSALS[..], call);
}