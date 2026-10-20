module bleu::brightness::engine_test;
import std::collections::maybe, std::time, bleu::availability, bleu::brightness, bleu::error, bleu::observe, bleu::operation, bleu::rt::worker, bleu::service, bleu::stream, bleu::unit;

// A platform in memory: one panel with a backlight and a gamma ramp.
struct World
{
	float level;
	float gamma;
	bool hardware_writable;
	bool hardware_fails;
	int hardware_writes;
	Platform platform;
}

// The poll is far away: the tests drive the engine with requests and never wait for a re-read.
const Duration TEST_POLL = (Duration)3_600_000_000;
const Duration TEST_STEP = (Duration)10_000;
const Duration WAIT      = (Duration)5_000_000;
const float TOLERANCE    = 0.01f;

fn State? world_read(void* context, Allocator allocator)
{
	World* world       = (World*)context;
	Control[] controls = alloc::new_array(allocator, Control, 2);
	Availability state = world.hardware_writable ? availability::YES
		: availability::no(availability::Reason.PERMISSION_NEEDED, "test: read-only");
	controls[0] = {
		.mechanism = Mechanism.BACKLIGHT,
		.readable = true,
		.writable = world.hardware_writable,
		.availability = state,
		.level = maybe::value((Level)world.level),
		.raw = maybe::value((long)(world.level * 100)),
		.raw_min = 0,
		.raw_max = 100,
	};
	controls[1] = {
		.mechanism = Mechanism.GAMMA,
		.readable = true,
		.writable = true,
		.availability = availability::YES,
		.level = maybe::value((Level)world.gamma),
	};
	Device[] devices = alloc::new_array(allocator, Device, 1);
	devices[0] = {
		.id = "panel".copy(allocator),
		.name = "test panel".copy(allocator),
		.kind = DeviceKind.PANEL,
		.controls = controls
	};
	return { .devices = devices };
}

fn Applied? world_write(void* context, String device_id, Mechanism mechanism, Level level)
{
	World* world = (World*)context;
	switch (mechanism)
	{
		case BACKLIGHT:
			if (world.hardware_fails) return error::raise(
				error::BACKEND_FAILURE,
				error::Domain.INTERNAL,
				0,
				"test: hardware refuses"
			)~;
			world.hardware_writes++;
			world.level = (float)level;
			return brightness::applied_at(
				Mechanism.BACKLIGHT,
				level,
				(long)(world.level * 100),
				0,
				100,
				maybe::value(level)
			);
		case GAMMA:
			world.gamma = (float)level;
			return brightness::applied_at(Mechanism.GAMMA, level, 0, 0, 1, maybe::value(level));
		case NATIVE:
		case DDC:
		case OVERLAY:
		case KEYBOARD_LED:
			return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "test: no such control")~;
	}
}

fn void world_run(void* state, BrightnessHub* hub, Host{Command}* host)
{
	World* world = (World*)state;
	brightness::serve(hub, host, &world.platform, TEST_POLL, TEST_STEP);
}

// Post one request straight to the worker and wait for its operation.
fn Applied? request(BrightnessHub* hub, Policy policy, Level level, Duration transition) @local
{
	SetOperation* op = operation::begin{Applied}(mem);
	defer op.release();
	Command command = {
		.kind = SET_LEVEL,
		.device_len = 5,
		.level = level,
		.policy = policy,
		.transition = transition,
		.operation = op
	};
	mem::copy(&command.device, "panel".ptr, 5);
	op.retain();
	hub.post(command)!!;
	return op.wait(WAIT);
}

fn World make_world(bool writable, bool fails) @local
{
	return {
		.level = 0.2f,
		.gamma = 1.0f,
		.hardware_writable = writable,
		.hardware_fails = fails,
		.platform = { .read = &world_read, .write = &world_write }
	};
}

fn void prefer_hardware_writes_the_backlight() @test
{
	World world = make_world(true, false);
	world.platform.context = &world;
	BrightnessHub hub;
	hub.start(mem, "test", "world", &world_run, &world)!!;
	defer hub.stop();
	Applied applied = request(&hub, brightness::prefer_hardware(), (Level)0.4f, time::DURATION_ZERO)!!;
	assert(applied.mechanism == Mechanism.BACKLIGHT && applied.raw == 40, "the writable backlight carries the request");
	assert(world.gamma == 1.0f, "no software change when hardware is writable");
	assert((float)applied.applied > 0.39f && (float)applied.applied < 0.41f);
	assert(applied.read_back.has_value && (float)applied.read_back.value > 0.39f, "read back after the write");
}

fn void prefer_hardware_uses_software_only_when_no_hardware_is_writable() @test
{
	World world = make_world(false, false);
	world.platform.context = &world;
	BrightnessHub hub;
	hub.start(mem, "test", "world", &world_run, &world)!!;
	defer hub.stop();
	Applied applied = request(&hub, brightness::prefer_hardware(), (Level)0.4f, time::DURATION_ZERO)!!;
	assert(applied.mechanism == Mechanism.GAMMA, "the result says it was software");
	assert(world.hardware_writes == 0 && world.level == 0.2f, "the backlight was not touched");
	assert(world.gamma > 0.39f && world.gamma < 0.41f);
}

fn void exact_on_a_read_only_control_is_refused_not_redirected() @test
{
	World world = make_world(false, false);
	world.platform.context = &world;
	BrightnessHub hub;
	hub.start(mem, "test", "world", &world_run, &world)!!;
	defer hub.stop();
	if (catch err = request(&hub, brightness::exact(Mechanism.BACKLIGHT), (Level)0.4f, time::DURATION_ZERO))
	{
		assert(err == error::PERMISSION_DENIED, "a read-only control named exactly is refused with its reason");
	}
	else
	{
		assert(false, "EXACT must not succeed through another mechanism");
	}
	assert(world.gamma == 1.0f, "software was not used behind the caller's back");
}

fn void hardware_failure_is_an_error_under_prefer_hardware() @test
{
	World world = make_world(true, true);
	world.platform.context = &world;
	BrightnessHub hub;
	hub.start(mem, "test", "world", &world_run, &world)!!;
	defer hub.stop();
	if (catch err = request(&hub, brightness::prefer_hardware(), (Level)0.4f, time::DURATION_ZERO))
	{
		assert(err == error::BACKEND_FAILURE);
	}
	else
	{
		assert(false, "a failing hardware write must fail under PREFER_HARDWARE");
	}
	assert(world.gamma == 1.0f, "no silent software dimming");
}

fn void hardware_failure_falls_back_only_under_allow_software() @test
{
	World world = make_world(true, true);
	world.platform.context = &world;
	BrightnessHub hub;
	hub.start(mem, "test", "world", &world_run, &world)!!;
	defer hub.stop();
	Applied applied = request(&hub, brightness::allow_software(), (Level)0.4f, time::DURATION_ZERO)!!;
	assert(applied.mechanism == Mechanism.GAMMA, "ALLOW_SOFTWARE moves on to the software ramp");
}

fn void transition_steps_to_the_target() @test
{
	World world = make_world(true, false);
	world.platform.context = &world;
	BrightnessHub hub;
	hub.start(mem, "test", "world", &world_run, &world)!!;
	defer hub.stop();
	Applied applied = request(&hub, brightness::prefer_hardware(), (Level)0.8f, (Duration)100_000)!!;
	assert((float)applied.applied > 0.79f && (float)applied.applied < 0.81f, "the last step is the target");
	assert(world.hardware_writes >= 2, "a transition writes several steps");
	assert(world.level > 0.79f && world.level < 0.81f);
}

fn void a_new_request_cancels_the_transition_in_progress() @test
{
	World world = make_world(true, false);
	world.platform.context = &world;
	BrightnessHub hub;
	hub.start(mem, "test", "world", &world_run, &world)!!;
	defer hub.stop();
	SetOperation* slow = operation::begin{Applied}(mem);
	defer slow.release();
	Command ramp = {
		.kind = SET_LEVEL,
		.device_len = 5,
		.level = (Level)1.0f,
		.policy = brightness::prefer_hardware(),
		.transition = (Duration)2_000_000,
		.operation = slow
	};
	mem::copy(&ramp.device, "panel".ptr, 5);
	slow.retain();
	hub.post(ramp)!!;
	if (catch err = request(&hub, brightness::prefer_hardware(), (Level)0.3f, time::DURATION_ZERO))
	{
		assert(false, "the second request should succeed");
	}
	if (catch err = slow.wait(WAIT))
	{
		assert(err == error::CANCELLED, "the replaced transition ends CANCELLED");
	}
	else
	{
		assert(false, "the replaced transition must not succeed");
	}
}
fn void a_level_change_is_announced_as_an_event() @test
{
	World world = make_world(true, false);
	world.platform.context = &world;
	BrightnessHub hub;
	hub.start(mem, "test", "world", &world_run, &world)!!;
	defer hub.stop();
	stream::Reader{Event}* reader = hub.events.subscribe()!!;
	defer reader.release();
	Applied applied = request(&hub, brightness::prefer_hardware(), (Level)0.4f, time::DURATION_ZERO)!!;
	assert(applied.raw == 40);
	Snapshot{Event}* packet = reader.next(WAIT)!!;
	defer packet.release();
	assert(packet.value.kind == EventKind.LEVEL_CHANGED, "the level moved");
	assert(packet.value.device_id == "panel"
		&& packet.value.mechanism == Mechanism.BACKLIGHT, "it names the device and the control");
}