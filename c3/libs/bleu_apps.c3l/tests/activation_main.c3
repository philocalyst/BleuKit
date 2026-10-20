// Driver for tests/run.sh: launches desktop entries over a private session bus
// and checks the route each launch took. Run with BLEU_APPS_ROOT set to the fake tree.
module activation_main;
import std::io, std::os::env, std::time, bleu::apps;

fn int main()
{
	String root = env::get_var(mem, "BLEU_APPS_ROOT") ?? "";
	assert(root.len > 0, "BLEU_APPS_ROOT names the fake tree");
	Apps* apps = apps::open(mem, { .backend = XDG_DESKTOP, .root = root, .settle = time::ms(50) })!!;
	defer apps.close();
	apps.wait_after(0, time::ms(3000))!!.release();

	// 1. A D-Bus-activatable entry: Activate, with the startup id and token.
	LaunchOperation* activate = apps.launch(
		"org.example.Activatable.desktop",
		{ .startup_id = "startup-1", .activation_token = "token-1" }
	)!!;
	defer activate.release();
	Launched first = activate.wait(time::ms(5000))!!;
	assert(first.route == DBUS_ACTIVATE, "the bus owns the name: the route is D-Bus");

	// 2. The same entry with a URI: Open.
	String[] uris         = { "file:///tmp/a.txt" };
	LaunchOperation* open = apps.launch("org.example.Activatable.desktop", { .uris = uris })!!;
	defer open.release();
	assert(open.wait(time::ms(5000))!!.route == DBUS_ACTIVATE);

	// 3. A desktop action: ActivateAction.
	LaunchOperation* action = apps.launch_action("org.example.Activatable.desktop", "second")!!;
	defer action.release();
	assert(action.wait(time::ms(5000))!!.route == DBUS_ACTIVATE);

	// 4. A name nobody owns and nothing can activate: the bus refuses, and the Exec line runs.
	LaunchOperation* fallback = apps.launch("org.example.Missing.desktop")!!;
	defer fallback.release();
	assert(fallback.wait(time::ms(5000))!!.route == SPAWN, "the Exec fallback ran");
	io::printn("activation checks passed");
	return 0;
}