<*
 The `gamma` module: DMS's night light (colour temperature on a schedule) on `bleu::color`.

 Methods: `wayland.gamma.getState`, `setTemperature`, `setLocation`, `setManualTimes`,
 `setUseIPLocation`, `setGamma`, `setEnabled`; and `wayland.icc.listOutputs`. Refused: the
 streaming `wayland.gamma.subscribe`, and the ICC profile and per-output methods
 (`wayland.icc.*`, `not supported`). Topic: `gamma` (DMS's `wayland.State`).

 Source of every shape and rule: `core/internal/server/wayland/` (types.go, handlers.go,
 manager.go) at DMS master 8be08999. The method names are the DMS names, `wayland.gamma.*`
 (`handlers.go:19-34`), as the router prefixes them (`router.go:125`). The settings and their
 mapping to bleu_color are in `mod_gamma_settings.c3`. Deviations are listed in docs/DMSD.md.
*>
module dmsd::gamma_mod;
import std::thread, std::time, std::collections::object, bleu::color, bleu::color::kelvin, bleu::color::schedule, bleu::error, bleu::ipc, bleu::json, bleu::observe, bleu::unit, dmsd::contract, dmsd::wire, dmsd::params, dmsd::replies, dmsd::theme_auto_calc, dmsd::gamma_settings;

const String[1] TOPICS       = { "gamma" };
const String[1] CAPABILITIES = { "gamma" };

// How long a request waits for bleu_color to write the ramps (the Wayland round trips are short).
const Duration WRITE_TIMEOUT = (Duration)5_000_000;
// The reply texts of the refused methods (replies.c3).
const String NOT_SUPPORTED_SUBSCRIBE = "not supported: a streaming method cannot reply in this protocol; subscribe with services [\"gamma\"] instead";
const String NOT_SUPPORTED_ICC       = "not supported: ICC profiles are not in bleu_color (its v1 cut)";
const String NOT_SUPPORTED_ICC_TEMP  = "not supported: bleu_color's per-output temperature stops the schedule for every output, which DMS does not do";
const String NOT_SUPPORTED_IP        = "not supported: IP geolocation is not available (Bleu has no geolocation service)";
const String NOT_SUPPORTED_GAMMA     = "not supported: bleu_color writes gamma 1.0 and contrast 1.0 only";
const String TEMPERATURE_ARGUMENTS   = "missing temperature parameters (provide 'temp' or both 'low' and 'high')";

// The refused methods of this module: each answers `not supported: <why>`.
const replies::Refusal[6] REFUSED = {
	{ .method = "wayland.gamma.subscribe", .text = NOT_SUPPORTED_SUBSCRIBE },
	{ .method = "wayland.icc.getStatus", .text = NOT_SUPPORTED_ICC },
	{ .method = "wayland.icc.apply", .text = NOT_SUPPORTED_ICC },
	{ .method = "wayland.icc.remove", .text = NOT_SUPPORTED_ICC },
	{ .method = "wayland.icc.setTemp", .text = NOT_SUPPORTED_ICC_TEMP },
	{ .method = "wayland.icc.getTemps", .text = NOT_SUPPORTED_ICC_TEMP },
};

<*
 The module's runtime state. Allocated in `start`, freed in `stop`. `command` serialises the
 setters (each one pushes to bleu_color and then stores); `state` guards `settings`, which the
 pump's thread reads.
*>
struct GammaModule
{
	Mutex command;
	Mutex state;
	GammaSettings settings;
	color::Color* service;
	observe::WatchId{color::State} watch_id;
	contract::StatePump state_pump;
}

// A copy of the settings, taken under the state mutex.
fn GammaSettings GammaModule.settings_now(&self)
{
	self.state.lock()!!;
	defer self.state.unlock();
	return self.settings;
}

// Store `settings` and publish. The caller holds the command mutex.
fn void GammaModule.store(&self, GammaSettings settings)
{
	self.state.lock()!!;
	self.settings = settings;
	self.state.unlock();
	self.state_pump.notify();
}

// The newest bleu_color state, or an empty one before the first reading. The caller releases the snapshot.
fn observe::Snapshot{color::State}*? GammaModule.latest(&self) => self.service.latest();

<*
 Hand `settings` to bleu_color as one command, and wait for it.

 A schedule that bleu_color's checks refuse is an error, and nothing is written. A display that
 refuses its ramp (another client holds its gamma control, or it has no gamma table) does not fail
 the command: bleu_color writes the other displays and reports the first refusal, and DMS does the
 same, keeping the settings and listing the display in `gammaRefused` (the state shows it). The
 refusal is logged here, and the settings are kept.

 @return? error::INVALID_ARGUMENT : "The schedule is not valid, as bleu_color checks it"
*>
fn void? GammaModule.push(&self, GammaSettings settings)
{
	color::ApplyOperation* op = self.command_for(settings)!;
	defer op.release();
	if (catch err = op.wait(WRITE_TIMEOUT))
	{
		contract::warn("gamma: %s", op.detail().message());
	}
}

// The bleu_color command for `settings`'s plan (see gamma_settings.plan_of). The caller releases it.
fn color::ApplyOperation*? GammaModule.command_for(&self, GammaSettings settings)
{
	switch (gamma_settings::plan_of(settings))
	{
		case gamma_settings::Plan.RESET:
			return self.service.reset();
		case gamma_settings::Plan.CONSTANT:
			return self.service.set_temperature(color::ALL_OUTPUTS, (unit::Kelvin)settings.low_temp);
		case gamma_settings::Plan.TIMES:
			return self.service.set_schedule(gamma_settings::times_schedule(settings));
		case gamma_settings::Plan.SUN:
			return self.service.set_schedule(gamma_settings::sun_schedule(settings));
	}
}

<*
 Check `candidate` as DMS validates a configuration, push it, and store it. Nothing is stored
 when the check or the push fails, so the settings stay as they were.
*>
fn void? GammaModule.change(&self, GammaSettings candidate)
{
	self.command.lock()!!;
	defer self.command.unlock();
	if (candidate.has_manual) schedule::validate(gamma_settings::times_schedule(candidate))!;
	self.push(candidate)!;
	self.store(candidate);
}

<*
 The temperatures of DMS's `Validate` for a configuration: each in bleu_color's kelvin range (`kelvin::MIN` to `kelvin::MAX`).
*>
fn void? check_temperatures(long low, long high)
{
	if (low < (long)kelvin::MIN || low > (long)kelvin::MAX || high < (long)kelvin::MIN || high > (long)kelvin::MAX)
	{
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"day and night must be %d to %d K",
			kelvin::MIN,
			kelvin::MAX
		)~;
	}
}

// The indices of `state`'s outputs in the order of their ids, in temporary memory (DMS sorts its names).
fn sz[] sorted_indices(color::State* state) @private
{
	sz[] order = alloc::new_array(tmem, sz, state.outputs.len);
	for (sz i = 0; i < order.len; i++) order[i] = i;
	for (sz i = 1; i < order.len; i++)
	{
		sz current = order[i];
		sz j       = i;
		while (j > 0 && state.outputs[order[j - 1]].id.compare_to(state.outputs[current].id) > 0)
		{
			order[j] = order[j - 1];
			j--;
		}
		order[j] = current;
	}
	return order;
}

// Whether a manual time or a location is set: DMS's `recalcSchedule` order of precedence (manual first).
fn bool has_times(GammaSettings s) @inline => s.has_manual || s.has_location;

// The times of today that DMS reports (`SunTimes`), from the manual times or the sun at the location.
// Zero when neither is set, or when the sun does not rise or set. `is_day` is derived from them.
struct DayTimes
{
	long dawn;
	long sunrise;
	long sunset;
	long night;
	bool is_day;
}

fn DayTimes day_times(GammaSettings s, long now)
{
	if (s.has_manual)
	{
		long day       = theme_auto_calc::local_day_of(now);
		long duration  = (s.has_duration ? s.duration_minutes : gamma_settings::DEFAULT_MANUAL_DURATION_MINUTES) * theme_auto_calc::MINUTE_US;
		long sunrise   = theme_auto_calc::local_instant(day, s.sunrise_minute);
		long sunset_day = s.sunset_minute > s.sunrise_minute ? day : day + 1;
		long sunset    = theme_auto_calc::local_instant(sunset_day, s.sunset_minute);
		return { .dawn = sunrise - duration, .sunrise = sunrise, .sunset = sunset, .night = sunset + duration, .is_day = now >= sunrise && now < sunset };
	}
	if (s.has_location)
	{
		theme_auto_calc::SunDay sun = theme_auto_calc::sun_times(s.latitude, s.longitude, s.elevation_twilight, s.elevation_daylight, now);
		if (sun.condition == theme_auto_calc::SunCondition.MIDNIGHT_SUN) return { .is_day = true };
		if (sun.condition == theme_auto_calc::SunCondition.POLAR_NIGHT) return { };
		return {
			.dawn = sun.times.dawn,
			.sunrise = sun.times.sunrise,
			.sunset = sun.times.sunset,
			.night = sun.times.night,
			.is_day = now >= sun.times.sunrise && now < sun.times.sunset,
		};
	}
	return { };
}

// The `Config` object (types.go:31-49). Go writes the fields by their names: the struct has no tags.
fn void? write_config(wire::Line* line, GammaSettings s)
{
	line.writer.begin_object()!;
	line.writer.key("Outputs")!;
	line.writer.begin_array()!;
	line.writer.end_array()!;
	wire::key_int(&line.writer, "LowTemp", s.low_temp)!;
	wire::key_int(&line.writer, "HighTemp", s.high_temp)!;
	if (s.has_location)
	{
		wire::key_double(&line.writer, "Latitude", s.latitude)!;
		wire::key_double(&line.writer, "Longitude", s.longitude)!;
	}
	else
	{
		wire::key_null(&line.writer, "Latitude")!;
		wire::key_null(&line.writer, "Longitude")!;
	}
	wire::key_bool(&line.writer, "UseIPLocation", s.use_ip_location)!;
	if (s.has_manual)
	{
		// Go's time.Parse("15:04") gives the year-zero date: 0000-01-01T HH:MM:00Z.
		wire::key_string(&line.writer, "ManualSunrise", string::tformat("0000-01-01T%02d:%02d:00Z", s.sunrise_minute / 60, s.sunrise_minute % 60))!;
		wire::key_string(&line.writer, "ManualSunset", string::tformat("0000-01-01T%02d:%02d:00Z", s.sunset_minute / 60, s.sunset_minute % 60))!;
	}
	else
	{
		wire::key_null(&line.writer, "ManualSunrise")!;
		wire::key_null(&line.writer, "ManualSunset")!;
	}
	if (s.has_duration)
	{
		// Go's time.Duration in nanoseconds (the handler's minutes times time.Minute).
		wire::key_int(&line.writer, "ManualDuration", s.duration_minutes * 60000000000)!;
	}
	else
	{
		wire::key_null(&line.writer, "ManualDuration")!;
	}
	wire::key_double(&line.writer, "Gamma", s.gamma)!;
	wire::key_double(&line.writer, "Contrast", s.contrast)!;
	wire::key_bool(&line.writer, "Enabled", s.enabled)!;
	wire::key_double(&line.writer, "ElevationTwilight", s.elevation_twilight)!;
	wire::key_double(&line.writer, "ElevationDaylight", s.elevation_daylight)!;
	line.writer.end_object()!;
}

<*
 One DMS `wayland.State` (types.go:51-64) from the settings and the newest bleu_color state
 (`state` is empty before its first reading). Fields dmsd does not compute are Go's zero values:
 `nextTransition`, `sunPosition`, and the ICC profiles (`{}`, there are none).
*>
fn String? render_state(Allocator allocator, GammaSettings s, color::State* state, long now)
{
	wire::Line line;
	line.begin(allocator);
	line.writer.begin_object()!;
	line.writer.key("config")!;
	write_config(&line, s)!;
	sz[] order = sorted_indices(state);
	long current_temp = 0;
	bool found_temp   = false;
	foreach (i : order)
	{
		if (state.outputs[i].control.temperature.has_value)
		{
			current_temp = (long)state.outputs[i].control.temperature.value;
			found_temp   = true;
			break;
		}
	}
	wire::key_int(&line.writer, "currentTemp", current_temp)!;
	wire::key_zero_time(&line.writer, "nextTransition")!;
	DayTimes day = day_times(s, now);
	bool timed   = has_times(s);
	if (timed)
	{
		wire::key_time(&line.writer, "sunriseTime", (Time)day.sunrise)!;
		wire::key_time(&line.writer, "sunsetTime", (Time)day.sunset)!;
		wire::key_time(&line.writer, "dawnTime", (Time)day.dawn)!;
		wire::key_time(&line.writer, "nightTime", (Time)day.night)!;
	}
	else
	{
		wire::key_zero_time(&line.writer, "sunriseTime")!;
		wire::key_zero_time(&line.writer, "sunsetTime")!;
		wire::key_zero_time(&line.writer, "dawnTime")!;
		wire::key_zero_time(&line.writer, "nightTime")!;
	}
	wire::key_bool(&line.writer, "isDay", timed && day.is_day)!;
	wire::key_double(&line.writer, "sunPosition", 0.0)!;
	line.writer.key("iccProfiles")!;
	line.writer.begin_object()!;
	line.writer.end_object()!;
	line.writer.key("outputTemps")!;
	line.writer.begin_object()!;
	foreach (i : order)
	{
		if (state.outputs[i].control.temperature.has_value)
		{
			wire::key_int(&line.writer, state.outputs[i].id, (long)state.outputs[i].control.temperature.value)!;
		}
	}
	line.writer.end_object()!;
	line.writer.key("outputs")!;
	line.writer.begin_array()!;
	foreach (i : order) line.writer.put_string(state.outputs[i].id)!;
	line.writer.end_array()!;
	bool any_refused = false;
	foreach (output : state.outputs) any_refused = any_refused || output.control.refused;
	if (any_refused)
	{
		line.writer.key("gammaRefused")!;
		line.writer.begin_array()!;
		foreach (i : order)
		{
			if (state.outputs[i].control.refused) line.writer.put_string(state.outputs[i].id)!;
		}
		line.writer.end_array()!;
	}
	line.writer.end_object()!;
	return line.finish();
}

// The pump's encoder: the settings with the newest bleu_color state, in temporary memory.
fn String? encode_state(void* context, Allocator allocator)
{
	GammaModule* m = (GammaModule*)context;
	GammaSettings s = m.settings_now();
	color::State empty;
	if (try snapshot = m.latest())
	{
		defer snapshot.release();
		return render_state(allocator, s, &snapshot.value, theme_auto_calc::now_us());
	}
	return render_state(allocator, s, &empty, theme_auto_calc::now_us());
}

// Listener: runs on bleu_color's thread. It only marks the pump dirty.
fn void on_state(void* context, observe::Snapshot{color::State}* snapshot)
{
	contract::StatePump* pump = (contract::StatePump*)context;
	pump.notify();
}

fn void handle_get_state(void* context, ipc::Call* call)
{
	GammaModule* m = (GammaModule*)context;
	@pool()
	{
		if (try line = encode_state(m, tmem))
		{
			call.respond_raw(line);
		}
		else
		{
			call.respond_error(contract::failure_text("failed to read the gamma state"));
		}
	};
}

// `temp` (a number) sets both temperatures; otherwise `low` and `high` are both required (handlers.go:56-75).
fn void? temperatures_of(Object* params, long* low, long* high) @private
{
	if (try value = json::read::get_double(params, "temp"))
	{
		*low  = (long)value;
		*high = (long)value;
		return;
	}
	if (try low_value = json::read::get_double(params, "low"))
	{
		if (try high_value = json::read::get_double(params, "high"))
		{
			*low  = (long)low_value;
			*high = (long)high_value;
			return;
		}
	}
	return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "%s", TEMPERATURE_ARGUMENTS)~;
}

fn void? set_temperature(GammaModule* m, ipc::Call* call) @private
{
	long low;
	long high;
	temperatures_of(call.params, &low, &high)!;
	check_temperatures(low, high)!;
	GammaSettings candidate = m.settings_now();
	candidate.low_temp  = low;
	candidate.high_temp = high;
	m.change(candidate)!;
	wire::respond_success(call, "temperature set")!;
}

fn void handle_set_temperature(void* context, ipc::Call* call)
{
	GammaModule* m = (GammaModule*)context;
	@pool()
	{
		if (catch set_temperature(m, call)) call.respond_error(contract::failure_text("failed to set the temperature"));
	};
}

fn void handle_set_location(void* context, ipc::Call* call)
{
	GammaModule* m = (GammaModule*)context;
	@pool()
	{
		if (catch set_location(m, call)) call.respond_error(contract::failure_text("failed to set the location"));
	};
}

fn void? set_location(GammaModule* m, ipc::Call* call) @private
{
	double latitude  = wire::required_double(call.params, "latitude")!;
	double longitude = wire::required_double(call.params, "longitude")!;
	if (!(latitude >= -90.0 && latitude <= 90.0))
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "latitude must be -90 to 90 degrees")~;
	}
	if (!(longitude >= -180.0 && longitude <= 180.0))
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "longitude must be -180 to 180 degrees")~;
	}
	GammaSettings candidate = m.settings_now();
	candidate.has_location = true;
	candidate.latitude = latitude;
	candidate.longitude = longitude;
	candidate.use_ip_location = false;
	m.change(candidate)!;
	wire::respond_success(call, "location set")!;
}

fn void handle_set_manual_times(void* context, ipc::Call* call)
{
	GammaModule* m = (GammaModule*)context;
	@pool()
	{
		if (catch set_manual_times(m, call)) call.respond_error(contract::failure_text("failed to set the manual times"));
	};
}

// Both times are needed to set them; otherwise they are cleared, with their duration (handlers.go:106-140).
fn void? set_manual_times(GammaModule* m, ipc::Call* call) @private
{
	GammaSettings candidate = m.settings_now();
	String sunrise_text = json::read::get_string(call.params, "sunrise") ?? "";
	String sunset_text  = json::read::get_string(call.params, "sunset") ?? "";
	if (sunrise_text.len == 0 || sunset_text.len == 0)
	{
		candidate.has_manual   = false;
		candidate.has_duration = false;
		m.change(candidate)!;
		wire::respond_success(call, "manual times cleared")!;
		return;
	}
	candidate.sunrise_minute = clock_or_raise(sunrise_text, "invalid sunrise format (use HH:MM)")!;
	candidate.sunset_minute  = clock_or_raise(sunset_text, "invalid sunset format (use HH:MM)")!;
	candidate.has_manual     = true;
	if (try minutes = json::read::get_double(call.params, "durationMinutes"))
	{
		candidate.has_duration     = true;
		candidate.duration_minutes = (long)minutes;
	}
	else
	{
		candidate.has_duration = false;
	}
	m.change(candidate)!;
	wire::respond_success(call, "manual times set")!;
}

// A clock value, or the DMS error text `message` (handlers.go:116-126).
fn long? clock_or_raise(String text, String message) @private
{
	if (try minute = gamma_settings::parse_clock(text)) return minute;
	return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "%s", message)~;
}

fn void handle_set_use_ip_location(void* context, ipc::Call* call)
{
	GammaModule* m = (GammaModule*)context;
	@pool()
	{
		if (catch set_use_ip_location(m, call)) call.respond_error(contract::failure_text("failed to set the IP location preference"));
	};
}

// `use` true needs a geolocation service Bleu does not have, so it is refused (replies.c3); false clears the flag.
fn void? set_use_ip_location(GammaModule* m, ipc::Call* call) @private
{
	bool use = params::param_bool(call.params, "use")!;
	if (use) return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "%s", NOT_SUPPORTED_IP)~;
	m.command.lock()!!;
	defer m.command.unlock();
	GammaSettings candidate = m.settings_now();
	candidate.use_ip_location = false;
	m.store(candidate);
	wire::respond_success(call, "IP location preference set")!;
}

fn void handle_set_gamma(void* context, ipc::Call* call)
{
	GammaModule* m = (GammaModule*)context;
	@pool()
	{
		if (catch set_gamma(m, call)) call.respond_error(contract::failure_text("failed to set gamma"));
	};
}

// bleu_color writes the neutral gamma and contrast only; the others are refused (replies.c3 has the text for the stream).
fn void? set_gamma(GammaModule* m, ipc::Call* call) @private
{
	double gamma    = wire::required_double(call.params, "gamma")!;
	double contrast = json::read::get_double(call.params, "contrast") ?? 1.0;
	if (gamma != 1.0 || contrast != 1.0)
	{
		return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "%s", NOT_SUPPORTED_GAMMA)~;
	}
	wire::respond_success(call, "gamma set")!;
}

fn void handle_set_enabled(void* context, ipc::Call* call)
{
	GammaModule* m = (GammaModule*)context;
	@pool()
	{
		if (catch set_enabled(m, call)) call.respond_error(contract::failure_text("failed to set the enabled state"));
	};
}

fn void? set_enabled(GammaModule* m, ipc::Call* call) @private
{
	bool enabled = params::param_bool(call.params, "enabled")!;
	GammaSettings candidate = m.settings_now();
	candidate.enabled = enabled;
	m.change(candidate)!;
	wire::respond_success(call, "enabled state set")!;
}

// `wayland.icc.listOutputs`: the connected output names, sorted (manager.go ListOutputs).
fn void handle_list_outputs(void* context, ipc::Call* call)
{
	GammaModule* m = (GammaModule*)context;
	@pool()
	{
		if (catch list_outputs(m, call)) call.respond_error(contract::failure_text("failed to list the outputs"));
	};
}

fn void? list_outputs(GammaModule* m, ipc::Call* call) @private
{
	wire::Line line;
	line.begin(tmem);
	line.writer.begin_array()!;
	color::State empty;
	if (try snapshot = m.latest())
	{
		defer snapshot.release();
		sz[] order = sorted_indices(&snapshot.value);
		foreach (i : order) line.writer.put_string(snapshot.value.outputs[i].id)!;
	}
	else
	{
		foreach (i : sorted_indices(&empty)) line.writer.put_string(empty.outputs[i].id)!;
	}
	line.writer.end_array()!;
	call.respond_raw(line.finish()!);
}

// Answers the refused methods (replies.c3).
fn void handle_refused(void* context, ipc::Call* call)
{
	replies::answer(REFUSED[..], call);
}

<* Start the module, or report why not and return false: no compositor, or no gamma control. *>
fn bool start(contract::Context* context, contract::Module* self)
{
	color::Options options = { .backend = color::Backend.AUTO };
	color::Color* service;
	if (try opened = color::open(context.allocator, options))
	{
		service = opened;
	}
	else
	{
		contract::warn("gamma: not started: %s", contract::failure_text("no backend"));
		return false;
	}
	GammaModule* m = alloc::new(context.allocator, GammaModule);
	m.service = service;
	m.settings = gamma_settings::default_settings();
	m.command.init()!!;
	m.state.init()!!;
	ipc::Topic* topic = context.server.register_topic("gamma")!!;
	context.server.register_method("wayland.gamma.getState", &handle_get_state, m)!!;
	context.server.register_method("wayland.gamma.setTemperature", &handle_set_temperature, m)!!;
	context.server.register_method("wayland.gamma.setLocation", &handle_set_location, m)!!;
	context.server.register_method("wayland.gamma.setManualTimes", &handle_set_manual_times, m)!!;
	context.server.register_method("wayland.gamma.setUseIPLocation", &handle_set_use_ip_location, m)!!;
	context.server.register_method("wayland.gamma.setGamma", &handle_set_gamma, m)!!;
	context.server.register_method("wayland.gamma.setEnabled", &handle_set_enabled, m)!!;
	context.server.register_method("wayland.icc.listOutputs", &handle_list_outputs, m)!!;
	replies::register_all(context.server, REFUSED[..], &handle_refused)!!;
	m.state_pump.start("gamma", topic, &encode_state, m)!!;
	m.watch_id = service.watch(&on_state, &m.state_pump);
	m.state_pump.notify();
	self.state = m;
	return true;
}

<* Stop the module: no more publications, then the service is closed. The server has stopped already. *>
fn void stop(contract::Context* context, contract::Module* self)
{
	GammaModule* m = (GammaModule*)self.state;
	m.service.unwatch(m.watch_id)!!;
	m.state_pump.stop();
	m.state_pump.free();
	m.service.close();
	m.command.destroy();
	m.state.destroy();
	alloc::free(context.allocator, m);
}

<* The module's descriptor for `main`. A global constant, so its slices point at static data. *>
const contract::Module DESCRIPTOR = {
	.name = "gamma",
	.start = &start,
	.stop = &stop,
	.topics = TOPICS[..],
	.capabilities = CAPABILITIES[..],
};

fn contract::Module descriptor() => DESCRIPTOR;
