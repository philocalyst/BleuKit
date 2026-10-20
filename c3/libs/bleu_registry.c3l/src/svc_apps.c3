<* The `apps` entry of the registry: open adapter, commands and `Spec`. *>
module bleu::registry::svc_apps;
import bleu::apps, bleu::registry, bleu::registry::live, bleu::json, bleu::operation, bleu::registry::tap;

<* Open the application catalogue with its default options. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	apps::Options opened = { .root = options.root };
	apps::Apps* service  = apps::open(allocator, opened)!;
	return (void*)service;
}

<*
 `apps.launch {app_id, action?}`: start an application, or one of its desktop
 actions when `action` is given. The reply names the route that was used and the pid.
*>
fn void? launch(registry::Request* request)
{
	apps::Apps* service              = (apps::Apps*)request.handle;
	String app_id                    = request.params.string("app_id")!;
	String action                    = registry::string_or(request.params, "action", "")!;
	apps::LaunchOperation* operation = action.len == 0 ? service.launch(app_id)!
		: service.launch_action(app_id, action)!;
	defer operation.release();
	apps::Launched launched = registry::await{apps::Launched}(operation, request.timeout)!;
	return registry::write_value(request.out, "launched", launched);
}

<* Every application scores the same, so the search is by name and keywords only. *>
fn int no_bonus(void* context, apps::App* app) @private
{
	return 0;
}

<*
 `apps.search {query, limit?}`: the applications that match `query`, best first.
 `limit` caps the reply and defaults to all matches.
*>
fn void? search(registry::Request* request)
{
	apps::Apps* service   = (apps::Apps*)request.handle;
	String query          = request.params.string("query")!;
	apps::Ranking ranking = service.search(query, &no_bonus, null, mem)!;
	defer ranking.release();
	apps::State state = ranking.snapshot.value;
	long limit        = request.params.int_or("limit", (long)ranking.hits.len)!;
	request.out.begin_object()!;
	request.out.key("ok")!;
	request.out.put_bool(true)!;
	request.out.key("apps")!;
	request.out.begin_array()!;
	for (usz i = 0; i < ranking.hits.len && (long)i < limit; i++)
	{
		apps::App app = state.apps[ranking.hits[i].index];
		request.out.begin_object()!;
		request.out.key("id")!;
		request.out.put_string(app.id)!;
		request.out.key("name")!;
		request.out.put_string(app.name)!;
		request.out.end_object()!;
	}
	request.out.end_array()!;
	return request.out.end_object();
}

const registry::Command[2] COMMANDS = {
	{ .name = "apps.launch", .summary = "Start an application: {app_id, action?}.", .run = &launch },
	{ .name = "apps.search", .summary = "Find applications: {query, limit?}.", .run = &search },
};

const registry::Spec APPS = {
	.name = "apps",
	.summary = "Application catalogue, search and launch (desktop entries, bundles, Start menu)",
	.open = &open,
	.close = &live::close{apps::Apps, apps::State, apps::Cap},
	.state = &live::state{apps::Apps, apps::State, apps::Cap},
	.state_after = &live::state_after{apps::Apps, apps::State, apps::Cap},
	.capabilities = &live::capabilities{apps::Apps, apps::State, apps::Cap},
	.backend = &live::backend{apps::Apps, apps::State, apps::Cap},
	.watch = &tap::watch{apps::Apps, apps::State},
	.commands = COMMANDS[..],
};