module bleu::apps;
import bleu::error, bleu::operation, bleu::rt::worker;

<*
 Arguments for a launch. Everything is copied when the launch is submitted, so the
 caller may reuse its arrays and strings straight away.

 `args` are appended to the command line of every process the launch starts.
 `files` and `uris` fill the field codes of the desktop entry (`%f`/`%F`,
 `%u`/`%U`); a launch that gives neither still runs.
 `activation_token` and `startup_id` are passed on to the child as
 `XDG_ACTIVATION_TOKEN` and `DESKTOP_STARTUP_ID`, so the new window can take focus.
 Use the token the compositor issued for this user action; it is single use.
*>
struct LaunchOptions
{
	String[] args;
	String[] files;
	String[] uris;
	String activation_token;
	String startup_id;
}

<*
 A submitted launch, owned by the mailbox until the worker serves it. The
 strings and slices live in `arena`; `op` is the worker's reference to the
 operation the caller is waiting on.
*>
struct LaunchRequest
{
	Allocator parent;
	DynamicArenaAllocator arena;
	String app_id;
	String action_id; // empty for the app itself
	String[] args;
	String[] files;
	String[] uris;
	String activation_token;
	String startup_id;
	LaunchOperation* op;
}

<*
 Copy a submission into a new request. `op` is a reference the request takes over.

 @param [&inout] allocator : "Allocator for the request; the request's arena draws its pages from it too"
*>
fn LaunchRequest* new_request(Allocator allocator, String app_id, String action_id, LaunchOptions options, LaunchOperation* op)
{
	LaunchRequest* request = alloc::new(allocator, LaunchRequest);
	request.parent = allocator;
	request.arena.init(allocator, REQUEST_PAGE_SIZE);
	request.app_id = app_id.copy(&request.arena);
	request.action_id = action_id.copy(&request.arena);
	request.args = copy_strings(&request.arena, options.args);
	request.files = copy_strings(&request.arena, options.files);
	request.uris = copy_strings(&request.arena, options.uris);
	request.activation_token = options.activation_token.copy(&request.arena);
	request.startup_id = options.startup_id.copy(&request.arena);
	request.op = op;
	return request;
}

const usz REQUEST_PAGE_SIZE = 1024;

<* Release the request, its strings, and the worker's reference to its operation. *>
fn void LaunchRequest.release(&self)
{
	Allocator parent = self.parent;
	self.op.release();
	self.arena.free();
	alloc::free(parent, self);
}

<*
 Copy every string of `values` into `allocator`, and return the new array (allocated from the same allocator).
*>
fn String[] copy_strings(Allocator allocator, String[] values)
{
	String[] copies = alloc::new_array(allocator, String, values.len);
	foreach (i, value : values) copies[i] = value.copy(allocator);
	return copies;
}

<* The worker's view of the service: its mailbox and stop flag. *>
alias AppsHost = Host{Command};

<* A command for the worker: rescan, or run a launch. *>
struct Command
{
	CommandKind kind;
	LaunchRequest* request; // for LAUNCH only
}

<*
 Serve the commands waiting in the mailbox, on the worker thread. `REFRESH` sets
 `refresh`; each `LAUNCH` is looked up in the latest catalogue and handed to
 `launch`, and its operation is completed with the result.
*>
fn void serve(void* state, AppsHub* hub, AppsHost* host, LaunchFn launch, bool* refresh)
{
	Command[COMMAND_BATCH] buffer;
	usz count;
	do
	{
		count = host.mailbox().take_all(buffer[..]);
		foreach (command : buffer[0:count])
		{
			if (command.kind == REFRESH)
			{
				*refresh = true;
				continue;
			}
			run_launch(state, hub, launch, command.request);
		}
	}
	while (count == buffer.len);
}

const usz COMMAND_BATCH = 8;

<*
 Fail every command still queued when the worker stops, so no caller waits forever.
*>
fn void refuse_pending(AppsHost* host)
{
	Command[COMMAND_BATCH] buffer;
	usz count;
	do
	{
		count = host.mailbox().take_all(buffer[..]);
		foreach (command : buffer[0:count])
		{
			if (command.kind == LAUNCH)
			{
				command.request.op.fail(error::DISCONNECTED);
				command.request.release();
			}
		}
	}
	while (count == buffer.len);
}

// Look up the app and action of one request, run the launch, complete the operation.
fn void run_launch(void* state, AppsHub* hub, LaunchFn launch, LaunchRequest* request) @local
{
	defer request.release();
	request.op.start();
	CatalogueSnapshot*? latest = hub.latest();
	if (catch err = latest)
	{
		request.op.fail(err);
		return;
	}
	CatalogueSnapshot* snapshot = latest;
	defer snapshot.release();
	App* app = find_by_id(&snapshot.value, request.app_id);
	if (!app)
	{
		request.op.fail(error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no app with id '%s'", request.app_id));
		return;
	}
	AppAction* action = null;
	if (request.action_id.len > 0)
	{
		action = find_action(app, request.action_id);
		if (!action)
		{
			request.op.fail(error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "'%s' has no action '%s'", app.id, request.action_id));
			return;
		}
	}
	Launched? result = launch(state, app, action, request);
	if (catch err = result)
	{
		request.op.fail(err);
		return;
	}
	request.op.succeed(result);
}

<* The action of `app` called `id`, or null. *>
fn AppAction* find_action(App* app, String id)
{
	foreach (&action : app.actions)
	{
		if (action.id == id) return action;
	}
	return null;
}

<*
 Run one launch on the worker thread. `action` is null for the app itself.

 @return? error::UNSUPPORTED : "This backend cannot run that kind of launch"
*>
alias LaunchFn = fn Launched?(void* state, App* app, AppAction* action, LaunchRequest* request);
