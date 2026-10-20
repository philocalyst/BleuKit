<*
 Configuration rules shared by every platform: a desired layout must name every output exactly
 once, sizes must be positive, and the enabled outputs must form a valid desktop. Also the
 comparison of a configuration with the current state, and the configuration that restores a
 state (used to roll back a change nobody confirmed). Pure; no platform code.
*>
module bleu::display;
import std::collections::maybe, bleu::error;

<* The index of the output with this id, or empty. *>
fn Maybe{usz} index_of_output(Output[] outputs, String id)
{
	for (usz i = 0; i < outputs.len; i++) {
		if (outputs[i].id == id) return maybe::value(i);
	}
	return { };
}

<* Where an enabled change lands on the desktop: its origin and its logical size. *>
fn Rect change_rect(OutputChange change)
{
	Extent size = logical_extent(change.mode, change.transform, scale_or_default(change.scale));
	return { .x = change.x, .y = change.y, .width = size.width, .height = size.height };
}

<*
 Check a desired layout against the outputs the service knows about.

 @param outputs : "The outputs of the current state"
 @return? error::INVALID_ARGUMENT : "An output is missing, named twice or unknown, a mode or scale is not positive, or the enabled outputs do not form a valid desktop"
*>
fn void? validate_config(Output[] outputs, Config config)
{
	if (config.outputs.len > MAX_LAYOUT_OUTPUTS) {
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "more than %d outputs", (int)MAX_LAYOUT_OUTPUTS)~;
	}
	if (config.outputs.len != outputs.len) {
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"the configuration names %d outputs, the system has %d",
			(int)config.outputs.len,
			(int)outputs.len
		)~;
	}
	Rect[MAX_LAYOUT_OUTPUTS] rects;
	usz enabled = 0;
	for (usz i = 0; i < config.outputs.len; i++) {
		OutputChange change = config.outputs[i];
		if (!index_of_output(outputs, change.output_id).has_value) {
			return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "unknown output %s", change.output_id)~;
		}
		for (usz j = 0; j < i; j++) {
			if (config.outputs[j].output_id == change.output_id) {
				return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "output %s is named twice", change.output_id)~;
			}
		}
		scale_check(change)!;
		if (!change.enabled) continue;
		if (change.mode.width == 0 || change.mode.height == 0) {
			return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "output %s has no mode", change.output_id)~;
		}
		rects[enabled++] = change_rect(change);
	}
	validate_layout(rects[0:enabled])!;
}

// A scale, when given, must be positive.
fn void? scale_check(OutputChange change) @private
{
	if (change.scale.has_value && !(change.scale.value > 0.0)) {
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "output %s has a scale that is not positive", change.output_id)~;
	}
}

<* How one output would change: which of its properties differ from the desired value. *>
struct OutputDelta
{
	bool enabled;
	bool mode;
	bool position;
	bool transform;
	bool scale;
}

<* True when any property differs. *>
fn bool OutputDelta.any(self) @inline => self.enabled || self.mode || self.position || self.transform || self.scale;

<*
 Compare one output with its desired change. Only properties the change sets are compared: a
 mode is compared only when the output is to be enabled, and an empty scale means "leave it".
*>
fn OutputDelta delta_of(Output current, OutputChange wanted)
{
	OutputDelta delta = { .enabled = current.enabled != wanted.enabled };
	if (!wanted.enabled) return delta;
	delta.mode = !current.current.has_value || !same_mode(current.current.value, wanted.mode);
	delta.position = current.x != wanted.x || current.y != wanted.y;
	delta.transform = current.transform != wanted.transform;
	delta.scale = wanted.scale.has_value && (!current.scale.has_value || current.scale.value != wanted.scale.value);
	return delta;
}

// Two modes name the same resolution, and the refresh rates agree (0 in `wanted` means any).
fn bool same_mode(Mode current, Mode wanted) @private
{
	if (current.width != wanted.width || current.height != wanted.height) return false;
	return wanted.refresh == 0 || refresh_matches(current.refresh, wanted.refresh, DEFAULT_REFRESH_TOLERANCE);
}

<*
 True when `config` would change anything in `state`: an output missing from the state counts as
 a change, and so does any output whose delta is not empty.
*>
fn bool config_changes(State state, Config config)
{
	foreach (change : config.outputs) {
		Maybe{usz} index = index_of_output(state.outputs, change.output_id);
		if (!index.has_value) return true;
		if (delta_of(state.outputs[index.value], change).any()) return true;
	}
	return false;
}

<*
 The configuration that restores `state`, allocated in `allocator`. A disabled output keeps an
 empty mode; a mode that was never reported stays empty and fails validation rather than guessing.
*>
fn Config config_from_state(State state, Allocator allocator)
{
	OutputChange[] changes = alloc::new_array(allocator, OutputChange, state.outputs.len);
	for (usz i = 0; i < state.outputs.len; i++) {
		Output output = state.outputs[i];
		Mode mode;
		if (output.current.has_value) mode = output.current.value;
		changes[i] = {
			.output_id = output.id.copy(allocator),
			.enabled = output.enabled,
			.mode = mode,
			.x = output.x,
			.y = output.y,
			.transform = output.transform,
			.scale = output.scale,
		};
	}
	return { .outputs = changes, .persistent = false };
}
