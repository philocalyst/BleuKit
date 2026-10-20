<*
 Array-valued request parameters, read the way dankgo's `params` package reads them
 (`params.StringSlice`, params/params.go): an absent or non-array member is an empty
 list, and an element of the wrong type is skipped. Modules that need an error for a
 missing array check `array_member` themselves.
*>
module dmsd::param_lists;
import std::collections::object, std::collections::list;

<* The array member `key` of `params`; NOT_FOUND when it is absent or is not an array. *>
fn Object*? array_member(Object* params, String key)
{
	Object* value = params.get(key)!;
	if (!value.is_array()) return NOT_FOUND~;
	return value;
}

<*
 The string elements of array member `key`, in order. Copied into `allocator`, which is
 the request's temporary memory in a handler.
*>
fn String[] strings(Object* params, String key, Allocator allocator)
{
	List{String} found;
	found.init(allocator);
	if (try list = array_member(params, key))
	{
		for (sz i = 0; i < list.get_len(); i++)
		{
			if (try text = list.get_string_at(i)) found.push(text.copy(allocator));
		}
	}
	return found.to_aligned_array(allocator);
}