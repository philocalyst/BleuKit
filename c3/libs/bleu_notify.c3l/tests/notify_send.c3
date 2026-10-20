// The sender as a command: sends one notification and prints its id.
//
//   notify_send <summary> [body] [--app NAME] [--replace ID] [--expire MS] [--urgency low|normal|critical]
//               [--category CAT] [--resident] [--action KEY LABEL]...
//
// stdout: BACKEND <name>, then SENT <id>; on failure SEND err=<fault> <message>, exit 3.
module notify_test_send;
import std::io, bleu::error, bleu::notify, bleu::notify::sender;

const usz MAX_ACTIONS = 8;

fn int usage_error(String flag)
{
	io::printfn("usage: unknown or invalid option %s", flag);
	return 2;
}

fn int main(String[] args)
{
	if (args.len < 2)
	{
		io::printfn("usage: notify_send <summary> [body] [options]");
		return 2;
	}
	sender::Sender*? opened = sender::open(mem);
	if (catch err = opened)
	{
		io::printfn("OPEN_FAILED %s %s", err, error::last().message());
		return 2;
	}
	sender::Sender* s = opened;
	defer s.close();
	io::printfn("BACKEND %s", s.backend_name());
	sender::Request request = sender::new_request(args[1]);
	request.app_name = "notify-send-test";
	notify::Action[MAX_ACTIONS] actions;
	usz action_count = 0;
	usz index = 2;
	if (args.len > 2 && !args[2].starts_with("--"))
	{
		request.body = args[2];
		index = 3;
	}
	while (index < args.len)
	{
		String flag = args[index];
		bool has_value = index + 1 < args.len;
		if (flag == "--app" && has_value)
		{
			request.app_name = args[index + 1];
		}
		else if (flag == "--replace" && has_value)
		{
			if (try id = (args[index + 1]).to_uint())
			{
				request.replaces_id = id;
			}
			else
			{
				return usage_error(flag);
			}
		}
		else if (flag == "--expire" && has_value)
		{
			if (try ms = (args[index + 1]).to_int())
			{
				request.expire_ms = ms;
			}
			else
			{
				return usage_error(flag);
			}
		}
		else if (flag == "--urgency" && has_value)
		{
			String level = args[index + 1];
			request.urgency = level == "low" ? notify::Urgency.LOW : (level == "critical" ? notify::Urgency.CRITICAL : notify::Urgency.NORMAL);
		}
		else if (flag == "--category" && has_value)
		{
			request.category = args[index + 1];
		}
		else if (flag == "--resident")
		{
			request.resident = true;
			index += 1;
			continue;
		}
		else if (flag == "--action" && index + 2 < args.len && action_count < MAX_ACTIONS)
		{
			actions[action_count++] = { .key = args[index + 1], .label = args[index + 2] };
			index += 3;
			continue;
		}
		else
		{
			return usage_error(flag);
		}
		index += 2;
	}
	request.actions = actions[:action_count];
	notify::NoteId? sent = s.send(request);
	if (catch err = sent)
	{
		io::printfn("SEND err=%s %s", err, error::last().message());
		return 3;
	}
	io::printfn("SENT %d", sent);
	return 0;
}
