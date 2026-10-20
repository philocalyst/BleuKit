// A notification centre as a test process. Started by run.sh on a private session bus.
// 
// stdin, one command per line:
//   close <id> <reason>        close an open notification (reason 1, 2 or 3)
//   invoke <id> <action-key>   invoke an action; closes the notification unless resident
//   dnd <0|1>                  do-not-disturb off or on
//   clear                      drop the history
//   state                      print the published state
//   sync                       print SYNC (a round trip, for the test)
//   quit                       stop and exit
// 
// Events (EVENT POSTED|CLOSED|ACTION_INVOKED lines) are printed by a second thread as they happen.
// 
// stdout: READY on success, OPEN_FAILED with the reason otherwise, then one line per answer.
module notify_test_server;
import std::atomic, std::io, std::thread, std::time, bleu::error, bleu::notify, bleu::operation, bleu::rt::foreign, bleu::stream;

fn int main(String[] args)
{
	notify::Options options;
	foreach (arg : args) if (arg == "--replace") options.replace = true;
	notify::Notify*? opened = notify::open(mem, options);
	if (catch err = opened)
	{
		io::printfn("OPEN_FAILED %s %s", err, error::last().message());
		return 2;
	}
	notify::Notify* centre                 = opened;
	// Events are printed by a second thread, which only reads its subscription.
	stream::Reader{notify::Event}*? events = centre.subscribe();
	if (catch err = events) return 2;
	Printing printing = { .events = events };
	Thread printer;
	printer.create(&print_events, &printing)!!;
	io::printfn("READY %s", centre.backend_name());
	bool running = true;
	while (running)
	{
		if (try line = io::treadline())
		{
			@pool()
			{
				running = handle(centre, line);
				io::printfn("END");
				io::stdout().flush()!!;
			};
		}
		else
		{
			running = false;
		}
	}
	// The printer stops first, then the subscription is released, and only then the centre (which frees its streams).
	printing.done.store(true);
	printer.join()!!;
	events.release();
	centre.close();
	return 0;
}

// What the printer thread reads: its subscription, and the flag main raises once the printer must stop.
struct Printing
{
	stream::Reader{notify::Event}* events;
	Atomic{bool} done;
}

// Print each event as it arrives, until the subscription closes with the centre.
fn int print_events(void* context)
{
	foreign::@foreign_entry()
	{
		Printing* printing = (Printing*)context;
		while (!printing.done.load())
		{
			// A timed read, so the flag is seen; a timeout or a closed stream just loops back to the flag.
			if (try packet = printing.events.next(time::ms(50)))
			{
				notify::Event event = packet.value;
				io::printfn(
					"EVENT %s id=%d replaced=%d reason=%d key=%s",
					event.kind == notify::EventKind.POSTED ? "POSTED"
						: (event.kind == notify::EventKind.CLOSED ? "CLOSED" : "ACTION_INVOKED"),
					event.id,
					event.replaced ? 1 : 0,
					(uint)event.reason,
					event.action_key
				);
				packet.release();
			}
		}
	};
	return 0;
}

// One command line. Returns false when the process should stop.
fn bool handle(notify::Notify* centre, String line)
{
	Splitter words = line.tokenize(" ");
	String verb    = words.next() ?? "";
	if (verb == "close")
	{
		uint id     = (words.next() ?? "0").to_uint()!!;
		uint reason = (words.next() ?? "0").to_uint()!!;
		close(centre, id, reason);
	}
	else if (verb == "invoke")
	{
		uint id    = (words.next() ?? "0").to_uint()!!;
		String key = words.next() ?? "";
		invoke(centre, id, key);
	}
	else if (verb == "dnd")
	{
		bool on = (words.next() ?? "0") == "1";
		if (catch err = centre.set_do_not_disturb(on))
		{
			io::printfn("DND err=%s", err);
		}
		else
		{
			io::printfn("DND ok");
		}
	}
	else if (verb == "clear")
	{
		if (catch err = centre.clear_history())
		{
			io::printfn("CLEAR err=%s", err);
		}
		else
		{
			io::printfn("CLEAR ok");
		}
	}
	else if (verb == "state")
	{
		print_state(centre);
	}
	else if (verb == "sync")
	{
		io::printfn("SYNC");
	}
	else if (verb == "quit")
	{
		io::printfn("BYE");
		return false;
	}
	else if (verb.len > 0)
	{
		io::printfn("UNKNOWN %s", verb);
	}
	return true;
}

fn void close(notify::Notify* centre, notify::NoteId id, uint reason)
{
	Operation{bool}* op = centre.close_notification(id, (notify::CloseReason)reason) ?? null;
	if (op == null)
	{
		io::printfn("CLOSE err=%s", error::last().message());
		return;
	}
	defer op.release();
	if (catch err = op.wait(time::sec(5)))
	{
		io::printfn("CLOSE err=%s %s", err, op.detail().message());
	}
	else
	{
		io::printfn("CLOSE ok");
	}
}

fn void invoke(notify::Notify* centre, notify::NoteId id, String key)
{
	Operation{bool}* op = centre.invoke_action(id, key) ?? null;
	if (op == null)
	{
		io::printfn("INVOKE err=%s", error::last().message());
		return;
	}
	defer op.release();
	if (catch err = op.wait(time::sec(5)))
	{
		io::printfn("INVOKE err=%s %s", err, op.detail().message());
	}
	else
	{
		io::printfn("INVOKE ok");
	}
}

fn void print_state(notify::Notify* centre)
{
	if (try snapshot = centre.latest())
	{
		defer snapshot.release();
		notify::State state = snapshot.value;
		io::printfn(
			"STATE serving=%d dnd=%d count=%d active=%d history=%d",
			state.serving ? 1 : 0,
			state.do_not_disturb ? 1 : 0,
			state.count,
			state.active.len,
			state.history.len
		);
		foreach (n : state.active) print_note("ACTIVE", n);
		foreach (n : state.history) print_note("HISTORY", n);
	}
	else
	{
		io::printfn("STATE none");
	}
}

fn void print_note(String kind, notify::Notification n)
{
	int progress = n.progress.has_value ? (int)((float)n.progress.value * 100.0f) : -1;
	io::printfn(
		"%s id=%d urgency=%d expires=%d summary=%s app=%s icon=%s category=%s desktop=%s tag=%s resident=%d transient=%d suppress=%d sound_name=%s sound_file=%s progress=%d image_path=%s",
		kind,
		n.id,
		(int)n.urgency,
		n.expires.has_value ? 1 : 0,
		n.summary,
		n.app_name,
		n.app_icon,
		n.category,
		n.desktop_entry,
		n.stack_tag,
		n.resident ? 1 : 0,
		n.transient ? 1 : 0,
		n.suppress_sound ? 1 : 0,
		n.sound_name,
		n.sound_file,
		progress,
		n.image_path
	);
	foreach (span : n.body)
	{
		io::printfn(
			"SPAN id=%d bold=%d italic=%d underline=%d link=%s text=%s",
			n.id,
			span.bold ? 1 : 0,
			span.italic ? 1 : 0,
			span.underline ? 1 : 0,
			span.link,
			span.text
		);
	}
	foreach (action : n.actions) io::printfn("ACTION id=%d key=%s label=%s", n.id, action.key, action.label);
	if (n.has_image)
	{
		ulong sum = 0;
		foreach (b : n.image.pixels) sum += (ulong)b;
		io::printfn(
			"IMAGE id=%d width=%d height=%d rowstride=%d alpha=%d channels=%d bytes=%d sum=%d",
			n.id,
			n.image.width,
			n.image.height,
			n.image.rowstride,
			n.image.has_alpha ? 1 : 0,
			n.image.channels,
			n.image.pixels.len,
			sum
		);
	}
}