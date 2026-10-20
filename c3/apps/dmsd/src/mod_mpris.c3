<*
 The `mpris.command` lease protocol, and why dmsd cannot run it on Bleu.

 DMS's `mpris.command` stream (`core/internal/server/server.go:660-671`) is fed by
 the bluez manager, not by an MPRIS client: `SubscribePlayerCommands` promotes one
 subscriber to command owner and hands it a `lease` (`bluez/manager.go:596-690`);
 AVRCP commands from a headset then arrive on that stream as `command` frames. The
 owner publishes the state of an MPRIS player it exports to BlueZ through
 `bluetooth.mpris.publish` with the lease (`bluez/handlers.go:63-80`,
 `PublishMPRIS`, `bluez/manager.go:710-719`). That is the whole protocol.

 Bleu has neither half. `bleu_bluetooth` does not build AVRCP on Linux (its README
 lists it as not done), and `bleu_media` observes and controls other players but its
 publishing side ("our own session") is cut from v1. So the stream is never sent, the
 lease is never granted, and `bluetooth.mpris.publish` is refused. `bleu_media` is not
 linked: nothing in the DMS core protocol reads the players it observes (the shell
 reads them itself). Deviations: docs/DMSD.md.

 `bluetooth.mpris.publish` is a method of DMS's bluetooth module. It is registered here
 because the lease exists only for it; a bluetooth module must take it over, not
 register it a second time.
*>
module dmsd::mpris_mod;
import bleu::ipc, dmsd::contract, dmsd::replies;

const String PUBLISH_REASON = "not supported: Bleu cannot export an MPRIS player to BlueZ (no AVRCP; bleu_media's publishing side is not built), so no lease is granted";

// The refused methods. One row: the publish side of the lease.
const replies::Refusal[1] REFUSALS = {
	{ .method = "bluetooth.mpris.publish", .text = PUBLISH_REASON },
};

// The module's descriptor for `main`. It has no state, no topic and no capability.
const contract::Module DESCRIPTOR = {
	.name = "mpris",
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
fn void stop(contract::Context* context, contract::Module* self) {}

fn void handle_refused(void* context, ipc::Call* call)
{
	replies::answer(REFUSALS[..], call);
}
