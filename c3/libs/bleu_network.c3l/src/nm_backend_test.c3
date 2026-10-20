// The NetworkManager backend's own memory, without a bus. A leak here fails the test run.
module bleu::network::nm_backend_test @feat(LINUX);
import std::collections::list, bleu::network::networkmanager;

// D17: transitions that arrived after the last settle still own their device paths; destroy frees them.
fn void destroy_frees_the_transitions_still_queued() @test
{
	networkmanager::Backend* b = alloc::new(mem, networkmanager::Backend);
	b.transitions.init(mem);
	b.pending.init(mem);
	b.prompts.init(mem);
	b.transitions.push({
		.sequence = 1,
		.device = "/org/freedesktop/NetworkManager/Devices/1".copy(mem),
		.state = 30,
		.reason = 0,
	});
	networkmanager::destroy(mem, b);
}
