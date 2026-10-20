<*
 The DMS core methods that are not a module's: `getServerInfo` and `shell.ready`.
 `ping` and `subscribe` belong to the IPC layer (bleu::ipc answers them itself,
 as dankgo does), and the handshake line is written by the same layer.

 Source: `core/internal/server/server.go` (ServerInfo at :50-54, getServerInfo at
 :511-517, `APIVersion` at :42), `core/internal/server/router.go:58-68` (shell.ready),
 `core/internal/server/models/types.go` (SuccessResult).
*>
module dmsd::core_methods;
import bleu::ipc, bleu::error, dmsd::contract, dmsd::wire;

// DMS's protocol version (server.go:42). The QML client's own check is against 1 and never fires.
const long API_VERSION = 38;
// The version this daemon reports as its `cliVersion` (DMS reports its build version).
const String CLI_VERSION = "0.1.0";
// The largest pid DMS accepts: `uint64(pid) > uint64(^uint32(0))` is rejected (router.go:60).
const long MAX_SHELL_PID = 4294967295;

<*
 Write `getServerInfo`: `{"apiVersion":38,"cliVersion":"...","capabilities":[...]}`.
 Capabilities are the started modules' names, the same list as the handshake.
*>
fn void get_server_info(void* context, ipc::Call* call)
{
	contract::Context* ctx = (contract::Context*)context;
	@pool()
	{
		if (catch server_info(ctx, call)) call.respond_error(contract::failure_text("cannot describe the server"));
	};
}

fn void? server_info(contract::Context* ctx, ipc::Call* call) @private
{
	wire::Line line;
	line.begin(tmem);
	json::JsonWriter* w = &line.writer;
	w.begin_object()!;
	wire::key_int(w, "apiVersion", API_VERSION)!;
	wire::key_string(w, "cliVersion", CLI_VERSION)!;
	wire::key_strings(w, "capabilities", ctx.capabilities)!;
	w.end_object()!;
	call.respond_raw(line.finish()!);
}

<*
 Answer `shell.ready {pid}`. DMS also tells its readiness tracker the shell's pid;
 that tracker is not part of this port (docs/DMSD.md), so the pid is only logged.
*>
fn void handle_shell_ready(void* context, ipc::Call* call)
{
	@pool()
	{
		if (catch shell_ready(call)) call.respond_error("invalid shell pid");
	};
}

fn void? shell_ready(ipc::Call* call) @private
{
	long pid = wire::param_int(call.params, "pid") ?? 0;
	if (pid <= 0 || pid > MAX_SHELL_PID)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "invalid shell pid")~;
	}
	contract::note("shell ready, pid %d", pid);
	wire::respond_success(call, "")!;
}
