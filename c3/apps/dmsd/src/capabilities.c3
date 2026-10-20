<*
 Capability names. DMS advertises one name per running service (getCapabilities,
 core/internal/server/server.go:429-509). dmsd advertises the names of the modules
 that started, in module order: the order `main` lists them in, which follows
 DMS's own order. DMS's four always-on names (`plugins`, `dgop`, `lyrics`,
 `lyrics.plugins`) are not advertised: dmsd does not provide those services.
*>
module dmsd::capabilities;
import std::collections::list, dmsd::contract;

<* Append the capability names of every started module to `names`, in module order. *>
fn void collect(contract::Module[] modules, List{String}* names)
{
	foreach (&mod : modules)
	{
		if (!mod.running) continue;
		foreach (name : mod.capabilities) names.push(name);
	}
}

<* The handshake's capability list, computed once at startup (`CapabilitiesFn`). *>
fn String[] handshake(void* context)
{
	contract::Context* ctx = (contract::Context*)context;
	return ctx.capabilities;
}
