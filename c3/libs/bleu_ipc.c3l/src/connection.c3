<*
 One client connection and its subscriptions. Owned by the I/O thread.

 A connection carries any number of subscriptions, each started by a `subscribe`
 request with its own id, as DMS multiplexes them. Every frame of a subscription
 carries that request's id.
*>
module bleu::ipc @feat(POSIX);
import std::collections::list, bleu::error, bleu::deadline, bleu::rt::unix, bleu::ipc::wire, bleu::ipc::line, bleu::ipc::outbox, std::collections::object;

<*
 One `subscribe` request. `wants` has one flag per topic, by topic index: the
 subscription receives that topic's frames.
*>
struct Subscription
{
	long request_id;
	bool[] wants;
}

<* One client. Created and destroyed by the I/O thread only. *>
struct Connection
{
	usz id;
	unix::UnixSocket socket;
	line::LineBuffer input;
	outbox::Outbox output;
	List{Subscription*} subscriptions;
	// Whether the poller currently waits for the socket to become writable.
	bool watching_writable;
	// True while the socket has refused output; the deadline then bounds the stall.
	bool stalled;
	Deadline stall_deadline;
}

<*
 Start a subscription from a `subscribe` request.

 `params.services` names the topics (a list of strings). Empty, absent, or
 without any string means every topic not marked explicit-only, as DMS does. The
 string "all" means the same, and a named explicit-only topic is included only
 when named. Unknown names are ignored. `params.clientId` is accepted and not used.

 The first frame is the `server` service with `ServerInfo`, then one snapshot per
 wanted topic that has one, in topic order (dankgo's and DMS's order).

 @return? error::OUT_OF_RANGE : "The client's output queue is full; the connection must close"
*>
fn void? Server.subscribe(&self, Connection* conn, long request_id, Object* params) @private
{
	Subscription* sub = alloc::new(self.allocator, Subscription);
	sub.request_id = request_id;
	usz topic_count = (usz)self.topics.len();
	sub.wants = alloc::new_array(self.allocator, bool, (sz)topic_count);
	for (usz t = 0; t < topic_count; t++) sub.wants[(sz)t] = false;
	self.choose_topics(sub.wants, params);
	conn.subscriptions.push(sub);
	for (usz t = 0; t < topic_count; t++)
	{
		if (sub.wants[(sz)t]) self.topics.get((sz)t).subscribers.add(1);
	}

	String info = self.server_info_json(self.allocator);
	String first = wire::service_frame(self.allocator, request_id, "server", info);
	alloc::free(self.allocator, info.ptr);
	conn.output.put(first, request_id, outbox::NO_KEY)!;

	for (usz t = 0; t < topic_count; t++)
	{
		if (!sub.wants[(sz)t]) continue;
		Topic* topic = self.topics.get((sz)t);
		topic.mutex.lock()!!;
		if (topic.has_snapshot)
		{
			String frame = wire::service_frame(self.allocator, request_id, topic.name, topic.snapshot);
			topic.mutex.unlock();
			conn.output.put(frame, request_id, (usz)t)!;
		}
		else
		{
			topic.mutex.unlock();
		}
	}
}

// Set `wants` for the topics named in a subscribe request's `services`.
fn void Server.choose_topics(&self, bool[] wants, Object* params) @private
{
	bool all = false;
	bool named = false;
	if (try services = params.get("services"))
	{
		if (services.is_array())
		{
			for (sz i = 0; i < services.get_len(); i++)
			{
				if (try name = services.get_string_at(i))
				{
					named = true;
					if (name == "all")
					{
						all = true;
						continue;
					}
					Topic* topic = self.find_topic(name);
					if (topic != null) wants[topic.index] = true;
				}
			}
		}
	}
	if (!named) all = true;
	if (!all) return;
	for (sz t = 0; t < wants.len; t++)
	{
		if (!self.topics.get(t).options.explicit_only) wants[t] = true;
	}
}
