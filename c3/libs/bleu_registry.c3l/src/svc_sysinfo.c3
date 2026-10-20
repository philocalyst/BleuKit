<* The `sysinfo` entry of the registry: open adapter, commands and `Spec`. *>
module bleu::registry::svc_sysinfo;
import bleu::sysinfo, bleu::registry, bleu::registry::live, bleu::json, bleu::operation, bleu::registry::tap;

<* Open the system information service. Its root points at a fake /proc, /sys and /etc in tests. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	sysinfo::Options opened = { .root = options.root };
	sysinfo::Sysinfo* service = sysinfo::open(allocator, opened)!;
	return (void*)service;
}

<*
 `sysinfo.kill {pid, mode?}`: signal a process. `mode` is `terminate` (the default)
 or `force`. The reply names the process and the mode that was used.
*>
fn void? kill(registry::Request* request)
{
	sysinfo::Sysinfo* service = (sysinfo::Sysinfo*)request.handle;
	uint pid = (uint)request.params.integer("pid")!;
	String mode = registry::string_or(request.params, "mode", "terminate")!;
	sysinfo::KillMode kind = registry::parse_enum{sysinfo::KillMode}(mode)!;
	Operation{sysinfo::KillReceipt}* operation = service.kill(pid, kind)!;
	defer operation.release();
	sysinfo::KillReceipt receipt = registry::await{sysinfo::KillReceipt}(operation, request.timeout)!;
	return registry::write_value(request.out, "receipt", receipt);
}

const registry::Command[1] COMMANDS = {
	{ .name = "sysinfo.kill", .summary = "Signal a process: {pid, mode?}.", .run = &kill },
};

const registry::Spec SYSINFO = {
	.name = "sysinfo",
	.summary = "CPU, memory, disks, network, temperatures and processes (procfs, Mach, Windows)",
	.open = &open,
	.close = &live::close{sysinfo::Sysinfo, sysinfo::State, sysinfo::Cap},
	.state = &live::state{sysinfo::Sysinfo, sysinfo::State, sysinfo::Cap},
	.state_after = &live::state_after{sysinfo::Sysinfo, sysinfo::State, sysinfo::Cap},
	.capabilities = &live::capabilities{sysinfo::Sysinfo, sysinfo::State, sysinfo::Cap},
	.backend = &live::backend{sysinfo::Sysinfo, sysinfo::State, sysinfo::Cap},
	.watch = &tap::watch{sysinfo::Sysinfo, sysinfo::State},
	.commands = COMMANDS[..],
};
