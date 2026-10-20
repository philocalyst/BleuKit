<*
 DMS request parameters, read the way DankMaterialShell's `dankgo/ipc/params`
 reads them (params/params.go:12-40). A missing or wrongly typed required
 parameter fails with "missing or invalid '<key>' parameter".
*>
module dmsd::params;
import std::collections::object, bleu::json, bleu::error;

<*
 Request parameters. The error texts are dankgo's (`params/params.go:12`):
 "missing or invalid '<key>' parameter". Numbers are read as Go reads them,
 as float64 and truncated to an integer.
*>
fn String? param_string(Object* params, String key)
{
	if (try value = json::read::get_string(params, key)) return value;
	return invalid_param(key)~;
}

<* A required number, truncated toward zero the way `params.Int` does. *>
fn long? param_int(Object* params, String key)
{
	if (try value = json::read::get_double(params, key)) return (long)value;
	return invalid_param(key)~;
}

<* A required number as a float64. *>
fn double? param_float(Object* params, String key)
{
	if (try value = json::read::get_double(params, key)) return value;
	return invalid_param(key)~;
}

<* A required boolean. *>
fn bool? param_bool(Object* params, String key)
{
	if (try value = json::read::get_bool(params, key)) return value;
	return invalid_param(key)~;
}

<* An optional boolean: `fallback` when absent or not a boolean (`params.BoolOpt`). *>
fn bool opt_bool(Object* params, String key, bool fallback)
{
	if (try value = json::read::get_bool(params, key)) return value;
	return fallback;
}

<* An optional integer: `fallback` when absent or not a number (`params.IntOpt`). *>
fn long opt_int(Object* params, String key, long fallback)
{
	if (try value = json::read::get_double(params, key)) return (long)value;
	return fallback;
}

<* An optional float64: `fallback` when absent or not a number (`params.FloatOpt`). *>
fn double opt_float(Object* params, String key, double fallback)
{
	if (try value = json::read::get_double(params, key)) return value;
	return fallback;
}

fn fault invalid_param(String key) @private
{
	return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "missing or invalid '%s' parameter", key);
}
