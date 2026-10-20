// Protocol driver: runs a real server in this process and runs the raw-socket
// Python checks (raw_protocol.py) against it. Exit code: the Python script's.
//
//   protocol_driver <socket path> <raw_protocol.py>
module protocol_driver;
import bleu::ipc, bleu::ipc::wire, std::io, std::os::process, std::time;

// The methods the Python script calls. `topic` is the topic `publish` writes to.
struct Context
{
	ipc::Server* server;
	ipc::Topic* live;
}

fn void answer_ok(void* context, ipc::Call* call)
{
	call.respond_raw("{\"ok\":true}");
}

// Publishes `params.value` on the `live` topic, then answers.
fn void publish_value(void* context, ipc::Call* call)
{
	Context* ctx = (Context*)context;
	String? value = call.params.get_string("value");
	if (catch err = value)
	{
		call.respond_error("publish needs a string value");
		return;
	}
	wire::Writer w;
	w.init(mem, value.len + 16);
	w.put("{\"value\":\"");
	w.put_escaped(value);
	w.put("\"}");
	String json = w.finish();
	if (catch err = ctx.live.publish(json)) io::printn("publish failed");
	alloc::free(mem, json.ptr);
	call.respond_raw("{\"published\":true}");
}

// Sends the capability change, so subscribers get a `server` frame.
fn void notify_caps(void* context, ipc::Call* call)
{
	Context* ctx = (Context*)context;
	if (catch err = ctx.server.notify_capabilities_changed()) io::printn("notify failed");
	call.respond_raw("{\"notified\":true}");
}

fn int main(String[] args)
{
	if (args.len != 3)
	{
		io::printn("usage: protocol_driver <socket path> <raw_protocol.py>");
		return 2;
	}
	String path = args[1];
	String script = args[2];
	ipc::Server server;
	server.init(mem, { .app_name = "driver", .api_version = 38, .socket_path = path,
		.capabilities = { "network", "bluetooth" }, .max_line = 4096, .write_stall = (Duration)2_000_000 })!!;
	defer server.free();
	ipc::Topic* live = server.register_topic("live")!!;
	ipc::Topic* snap = server.register_topic("snap")!!;
	snap.publish("{\"n\":1}")!!;
	Context ctx = { .server = &server, .live = live };
	server.register_method("echo", &answer_ok, null)!!;
	server.register_method("publish", &publish_value, &ctx)!!;
	server.register_method("caps", &notify_caps, &ctx)!!;
	server.start()!!;
	defer server.stop();

	String[] command = { "python3", "-I", script, path };
	int code = process::run(command, process::SpawnOptions.INHERIT_ENV, {}, process::INHERIT, process::INHERIT, process::INHERIT)!!;
	io::printfn("raw protocol checks exited with %d", code);
	return code;
}
