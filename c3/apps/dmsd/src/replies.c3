<*
 Refused methods: DMS methods that dmsd knows by name but cannot serve on Bleu.

 Each refused method answers `not supported: <why>` (docs/DMSD.md, "Coverage"), so the
 shell can tell "this machine has no such service" from "this daemon has no such method"
 (`unknown method`). A module lists its refused methods in a table of `Refusal` rows and
 registers them with `register_all`; `answer` looks the row up by the call's method name.
 A refused method is never advertised as a capability.
*>
module dmsd::replies;
import bleu::ipc;

<*
 One refused method: its DMS name and the whole reply text, which starts with
 `not supported: `. The text is a constant, so a row needs no allocation.
*>
struct Refusal
{
	String method;
	String text;
}

<*
 Register every row of `table` on `server`, each answered by `handler`. Call before the
 server starts, as for any method.

 @return? error::INVALID_STATE : "The server has already started"
*>
fn void? register_all(ipc::Server* server, Refusal[] table, ipc::Handler handler)
{
	foreach (&row : table)
	{
		server.register_method(row.method, handler, null)!;
	}
}

<*
 Answer `call` with the reply of its row in `table`. A method missing from the table
 (which the registration makes impossible) gets the server's `unknown method` text.
*>
fn void answer(Refusal[] table, ipc::Call* call)
{
	foreach (&row : table)
	{
		if (row.method == call.method)
		{
			call.respond_error(row.text);
			return;
		}
	}
	call.respond_error("unknown method");
}
</content>
