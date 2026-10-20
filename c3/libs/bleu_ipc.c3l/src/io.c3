<*
 The I/O thread: the one thread that reads requests, writes replies and frames,
 and accepts connections. It loops over four steps:

 1. apply the commands other threads posted (publications, replies, capability changes),
 2. write what the sockets accept now,
 3. wait for readiness (bounded by the nearest write-stall deadline) and handle it,
 4. disconnect clients whose stall deadline has passed.

 Requests are parsed here, so `ping`, `subscribe` and protocol errors never wait
 behind a handler; only registered methods go to the handler threads.
*>
module bleu::ipc @feat(POSIX);
import std::collections::list, std::thread, std::atomic, std::time, bleu::error, bleu::deadline, bleu::rt::worker, bleu::rt::poller, bleu::rt::unix, bleu::ipc::wire, bleu::ipc::line, bleu::ipc::outbox, std::collections::object;

<* What another thread asks the I/O thread to do. *>
enum IoKind : char
{
	// Fan a state value out to the subscriptions of `topic`; it becomes the snapshot.
	PUBLISH,
	// Fan one event out to the subscriptions of `topic`, without keeping it.
	PUBLISH_EVENT,
	// Queue a complete reply frame for connection `conn_id`.
	REPLY,
	// Send the `server` frame with the current capabilities on every subscription.
	CAPABILITIES,
}

<*
 A command for the I/O thread. `bytes` belongs to the command until the I/O thread
 takes it: the JSON value of a publication, or a complete reply frame. A command
 that is refused releases its bytes where it was refused.
*>
struct IoCommand
{
	IoKind kind;
	Topic* topic;
	usz conn_id;
	String bytes;
}

<* Commands taken from the mailbox per batch. *>
const usz IO_BATCH = 32;

<* Poller interest of a connection: readable always, writable while output waits. *>
fn poller::Interest connection_interest(bool writable) @private
{
	poller::Interest interest;
	interest.readable = true;
	interest.writable = writable;
	return interest;
}

<* Source of a connection, as the poller needs it. *>
fn poller::Source connection_source(Connection* conn, bool writable) @private
{
	return { .handle = conn.socket.fd.raw(), .interest = connection_interest(writable), .tag = conn.id };
}

<*
 Hand a command to the I/O thread. When the queue refuses it, the command's bytes
 are released here.

 @return? error::UNAVAILABLE : "The server is stopped"
 @return? error::BUSY : "The I/O queue is full"
*>
fn void? Server.post_io(&self, IoCommand command)
{
	if (catch err = self.io.mailbox.post(command))
	{
		if (command.bytes.len > 0) alloc::free(self.allocator, command.bytes.ptr);
		return err~;
	}
}

<*
 Queue a reply frame for a request, from any thread. The frame is released if the
 I/O thread cannot take it.

 @return? error::UNAVAILABLE, error::BUSY : "The reply could not be queued"
*>
fn void? Server.post_reply(&self, usz conn_id, String frame)
{
	return self.post_io({ .kind = REPLY, .conn_id = conn_id, .bytes = frame });
}

// The I/O thread's entry point. Runs until the worker is stopped.
fn void io_main(void* context, worker::Host{IoCommand}* host)
{
	Server* server = (Server*)context;
	IoCommand[IO_BATCH] batch;
	while (!host.stopping())
	{
		server.apply_commands(host, batch[..]);
		server.serve_once();
		server.expire_stalls();
	}
	server.shutdown_io(host, batch[..]);
}

// Take and apply every queued command, then write what the sockets accept.
fn void Server.apply_commands(&self, worker::Host{IoCommand}* host, IoCommand[] batch)
{
	bool applied = false;
	while (true)
	{
		usz taken = host.mailbox().take_all(batch);
		if (taken == 0) break;
		applied = true;
		for (usz i = 0; i < taken; i++) self.apply(batch[(sz)i]);
	}
	if (applied) self.flush_all();
}

// Apply one command.
fn void Server.apply(&self, IoCommand command)
{
	switch (command.kind)
	{
		case PUBLISH:
			self.fan_out(command.topic, command.bytes, true);
		case PUBLISH_EVENT:
			self.fan_out(command.topic, command.bytes, false);
		case REPLY:
			self.deliver_reply(command.conn_id, command.bytes);
		case CAPABILITIES:
			self.fan_out_capabilities();
	}
}

<*
 Wait for readiness, bounded by the nearest stall deadline, and handle it: accept
 new clients, read from ready clients. Then write what can go out.
*>
fn void Server.serve_once(&self)
{
	Ready[]? ready = self.io_poller.wait(self.next_stall_wait());
	if (catch err = ready)
	{
		// TIMEOUT is the normal end of an idle wait. poll(2) fails only on a descriptor
		// this thread owns, which is a programming error.
		if (err != TIMEOUT) unreachable("poll(2) failed on a descriptor the I/O thread owns");
	}
	else
	{
		for (sz i = 0; i < ready.len; i++)
		{
			poller::Ready event = ready[i];
			if (event.tag == LISTENER_TAG)
			{
				self.accept_pending();
				continue;
			}
			Connection* conn = self.find_connection(event.tag);
			if (conn == null) continue;
			if (event.events.readable || event.events.hangup || event.events.failed)
			{
				if (!self.read_from(conn)) self.close_connection(conn);
			}
		}
	}
	self.flush_all();
}

// The time the poller may wait: until the nearest stall deadline, or forever.
fn Duration Server.next_stall_wait(&self)
{
	Duration wait = time::FOREVER;
	for (sz i = 0; i < self.connections.len(); i++)
	{
		Connection* conn = self.connections.get(i);
		if (!conn.stalled) continue;
		Duration left = conn.stall_deadline.remaining();
		if (left < wait) wait = left;
	}
	return wait;
}

// Disconnect every client that has refused output for longer than the write-stall limit.
fn void Server.expire_stalls(&self)
{
	for (sz i = (sz)self.connections.len() - 1; i >= 0; i--)
	{
		Connection* conn = self.connections.get(i);
		if (conn.stalled && conn.stall_deadline.expired()) self.close_connection(conn);
	}
}

// Write queued output of every client, and keep each poller interest in step with its queue.
fn void Server.flush_all(&self)
{
	for (sz i = (sz)self.connections.len() - 1; i >= 0; i--)
	{
		Connection* conn = self.connections.get(i);
		if (!self.flush(conn) || !self.sync_interest(conn)) self.close_connection(conn);
	}
}

// Write as much of the queue as the socket accepts. False when the client is gone.
fn bool Server.flush(&self, Connection* conn)
{
	while (!conn.output.is_empty())
	{
		outbox::Frame* frame = conn.output.front();
		String rest          = frame.bytes[(sz)frame.sent:(sz)((usz)frame.bytes.len - frame.sent)];
		usz? accepted        = conn.socket.send((char[])rest);
		if (catch err = accepted)
		{
			if (err == error::BUSY)
			{
				if (!conn.stalled)
				{
					conn.stalled = true;
					conn.stall_deadline = deadline::after(self.config.write_stall);
				}
				return true;
			}
			return false;
		}
		conn.stalled = false;
		conn.output.advance(accepted);
	}
	conn.stalled = false;
	return true;
}

// Make the poller wait for writability exactly while output is queued. False when the poller refuses.
fn bool Server.sync_interest(&self, Connection* conn)
{
	bool want = !conn.output.is_empty();
	if (want == conn.watching_writable) return true;
	if (catch self.io_poller.remove(conn.id)) return false;
	if (catch self.io_poller.add(connection_source(conn, want))) return false;
	conn.watching_writable = want;
	return true;
}

// Read what the socket has now and handle every complete line. False when the client must close.
fn bool Server.read_from(&self, Connection* conn)
{
	char[] room     = conn.input.reserve();
	RecvResult? got = conn.socket.recv(room, { });
	if (catch err = got)
	{
		// Nothing to read yet keeps the client; a closed or broken connection does not.
		return err == error::BUSY;
	}
	conn.input.commit(got.bytes);
	return self.process_lines(conn);
}

// Handle every complete line buffered for a client. False when the client must close.
fn bool Server.process_lines(&self, Connection* conn)
{
	while (true)
	{
		String? next = conn.input.next_line();
		if (catch err = next)
		{
			// NO_MORE_ELEMENT: wait for more bytes. OUT_OF_RANGE: the line is too long, so close.
			return err == NO_MORE_ELEMENT;
		}
		if (!self.handle_line(conn, next)) return false;
	}
}

// Handle one request line: answer it here, or send it to a handler thread.
fn bool Server.handle_line(&self, Connection* conn, String line)
{
	Job* job = alloc::new(self.allocator, Job);
	job.allocator = self.allocator;
	job.arena.init(self.allocator, JOB_ARENA_CHUNK);
	ParsedRequest? parsed = parse_request(line, &job.arena);
	if (catch err = parsed)
	{
		String message = error::last().message();
		job.free();
		return self.reply_error(conn, 0, message);
	}
	ParsedRequest request = parsed;
	if (request.method == "ping")
	{
		job.free();
		return self.reply_result(conn, request.id, "{\"pong\":true}");
	}
	if (request.method == "subscribe")
	{
		job.free();
		if (catch self.subscribe(conn, request.id, request.params)) return false;
		return true;
	}
	Method* method = self.find_method(request.method);
	if (method == null)
	{
		job.free();
		return self.reply_unknown(conn, request.id, request.method);
	}
	return self.dispatch(conn, job, method, request);
}

// Send a request to a handler thread, on the least busy one.
fn bool Server.dispatch(&self, Connection* conn, Job* job, Method* method, ParsedRequest request)
{
	Pending* pending = new_pending(self.allocator, self, conn.id, request.id);
	job.method = method;
	job.pending = pending;
	job.id = request.id;
	job.name = request.method;
	job.params = request.params;
	PoolSlot* slot = self.least_busy_slot();
	slot.in_flight.add(1);
	if (catch err = slot.worker.mailbox.post(job))
	{
		slot.in_flight.sub(1);
		pending.release();
		job.free();
		return self.reply_error(conn, request.id, "server is busy");
	}
	return true;
}

// The handler thread with the fewest requests in progress or queued.
fn PoolSlot* Server.least_busy_slot(&self)
{
	PoolSlot* best = &self.slots[0];
	for (sz i = 1; i < self.slots.len; i++)
	{
		if (self.slots[i].in_flight.load() < best.in_flight.load()) best = &self.slots[i];
	}
	return best;
}

// Queue an error reply. False when the client's queue refuses it.
fn bool Server.reply_error(&self, Connection* conn, long request_id, String message)
{
	return self.enqueue(conn, wire::error_frame(self.allocator, request_id, message), request_id, outbox::NO_KEY);
}

// Queue a `method not found` reply.
fn bool Server.reply_unknown(&self, Connection* conn, long request_id, String method)
{
	String frame;
	@pool()
	{
		frame = wire::error_frame(self.allocator, request_id, string::tformat("unknown method: %s", method));
	};
	return self.enqueue(conn, frame, request_id, outbox::NO_KEY);
}

// Queue a result reply. False when the client's queue refuses it.
fn bool Server.reply_result(&self, Connection* conn, long request_id, String json)
{
	return self.enqueue(conn, wire::result_frame(self.allocator, request_id, json), request_id, outbox::NO_KEY);
}

// Queue a frame for a client. False when the queue refuses it: the client must close.
fn bool Server.enqueue(&self, Connection* conn, String frame, long request_id, usz key)
{
	if (catch conn.output.put(frame, request_id, key)) return false;
	return true;
}

// Accept every connection waiting on the listener.
fn void Server.accept_pending(&self)
{
	while (true)
	{
		unix::UnixSocket? accepted = self.listener.accept();
		if (catch accepted) return;
		unix::UnixSocket socket = accepted;
		if (self.connections.len() >= (sz)self.config.max_clients)
		{
			socket.close();
			continue;
		}
		self.add_connection(socket);
	}
}

// Set up an accepted connection and send its handshake.
fn void Server.add_connection(&self, unix::UnixSocket socket)
{
	Connection* conn = alloc::new(self.allocator, Connection);
	conn.id = self.next_connection_id;
	self.next_connection_id++;
	conn.socket = socket;
	conn.input.init(self.allocator, self.config.max_line);
	conn.output.init(self.allocator, self.config.max_queued_bytes);
	conn.subscriptions.init(self.allocator, 2);
	conn.watching_writable = false;
	conn.stalled = false;
	self.connections.push(conn);
	if (catch conn.socket.fd.set_nonblocking(true))
	{
		self.close_connection(conn);
		return;
	}
	if (catch self.io_poller.add(connection_source(conn, false)))
	{
		self.close_connection(conn);
		return;
	}
	String[] caps    = self.capabilities_now();
	String handshake = wire::handshake_frame(self.allocator, self.config.api_version, caps);
	if (!self.enqueue(conn, handshake, 0, outbox::NO_KEY)) self.close_connection(conn);
}

// Queue a reply frame that a handler produced, if its connection is still open.
fn void Server.deliver_reply(&self, usz conn_id, String frame)
{
	Connection* conn = self.find_connection(conn_id);
	if (conn == null)
	{
		alloc::free(self.allocator, frame.ptr);
		return;
	}
	if (!self.enqueue(conn, frame, 0, outbox::NO_KEY)) self.close_connection(conn);
}

// Fan a publication out to every subscription that wants `topic`.
fn void Server.fan_out(&self, Topic* topic, String data, bool state)
{
	for (sz i = (sz)self.connections.len() - 1; i >= 0; i--)
	{
		Connection* conn = self.connections.get(i);
		if (!self.fan_out_to(conn, topic, data, state)) self.close_connection(conn);
	}
	alloc::free(self.allocator, data.ptr);
}

// Queue a publication on every subscription of one client that wants `topic`. False when the queue refuses.
fn bool Server.fan_out_to(&self, Connection* conn, Topic* topic, String data, bool state)
{
	for (sz s = 0; s < conn.subscriptions.len(); s++)
	{
		Subscription* sub = conn.subscriptions.get(s);
		if (!sub.wants[topic.index]) continue;
		String frame = wire::service_frame(self.allocator, sub.request_id, topic.name, data);
		usz key      = state ? topic.index : outbox::NO_KEY;
		if (catch conn.output.put(frame, sub.request_id, key)) return false;
	}
	return true;
}

// Send the `server` frame with the current capabilities on every subscription.
fn void Server.fan_out_capabilities(&self)
{
	String info = self.server_info_json(self.allocator);
	for (sz i = (sz)self.connections.len() - 1; i >= 0; i--)
	{
		Connection* conn = self.connections.get(i);
		if (!self.server_frames_to(conn, info)) self.close_connection(conn);
	}
	alloc::free(self.allocator, info.ptr);
}

// Queue a `server` frame on every subscription of one client. False when the queue refuses.
fn bool Server.server_frames_to(&self, Connection* conn, String info)
{
	for (sz s = 0; s < conn.subscriptions.len(); s++)
	{
		Subscription* sub = conn.subscriptions.get(s);
		String frame      = wire::service_frame(self.allocator, sub.request_id, "server", info);
		if (catch conn.output.put(frame, sub.request_id, SERVER_KEY)) return false;
	}
	return true;
}

// The `ServerInfo` JSON value, now.
fn String Server.server_info_json(&self, Allocator allocator)
{
	return wire::server_info(allocator, self.config.api_version, self.capabilities_now());
}

// The connection with this id, or null.
fn Connection* Server.find_connection(&self, usz id)
{
	for (sz i = 0; i < self.connections.len(); i++)
	{
		Connection* conn = self.connections.get(i);
		if (conn.id == id) return conn;
	}
	return null;
}

<*
 Close a connection: its poller registration, its subscriptions (which stop
 counting towards their topics), its queues and its socket.
*>
fn void Server.close_connection(&self, Connection* conn)
{
	if (catch self.io_poller.remove(conn.id))
	{
	}
	for (sz s = 0; s < conn.subscriptions.len(); s++)
	{
		Subscription* sub = conn.subscriptions.get(s);
		for (sz t = 0; t < sub.wants.len; t++)
		{
			if (sub.wants[t]) self.topics.get(t).subscribers.sub(1);
		}
		alloc::free(self.allocator, sub.wants.ptr);
		alloc::free(self.allocator, sub);
	}
	conn.subscriptions.free();
	conn.output.free();
	conn.input.free();
	conn.socket.close();
	for (sz i = 0; i < self.connections.len(); i++)
	{
		if (self.connections.get(i) == conn)
		{
			self.connections.remove_at(i);
			break;
		}
	}
	alloc::free(self.allocator, conn);
}

// Runs once the loop has stopped, on the I/O thread: closes everything and frees
// the commands that were queued but never taken, so their bytes do not leak.
fn void Server.shutdown_io(&self, worker::Host{IoCommand}* host, IoCommand[] batch)
{
	for (sz i = (sz)self.connections.len() - 1; i >= 0; i--) self.close_connection(self.connections.get(i));
	self.listener.close();
	while (host.mailbox().pending() > 0)
	{
		usz taken = host.mailbox().take_all(batch);
		for (usz i = 0; i < taken; i++)
		{
			if (batch[(sz)i].bytes.len > 0) alloc::free(self.allocator, batch[(sz)i].bytes.ptr);
		}
	}
}