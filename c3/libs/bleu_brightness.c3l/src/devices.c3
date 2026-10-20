<*
 Building `Device` values for a platform's read: every string and control array
 goes into the snapshot's allocator, so the state outlives the pass that built it.
*>
module bleu::brightness;
import std::collections::list;

<*
 Append a device to `devices`. `id`, `name` and `controls` are copied into `allocator`.
*>
fn void add_device(Allocator allocator, List{Device}* devices, String id, String name, DeviceKind kind, Control[] controls)
{
	devices.push({
		.id = id.copy(allocator),
		.name = name.copy(allocator),
		.kind = kind,
		.controls = alloc::clone_slice(allocator, controls),
	});
}
