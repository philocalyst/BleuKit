<*
 DRM connectors and their DDC/CI buses, from `/sys/class/drm`.

 A connected connector `card<N>-<CONNECTOR>` has a `ddc` symbolic link to the
 I2C adapter that carries its DDC/CI lines. The adapter's number is the `i2c-<N>`
 leaf of the link target, and `/dev/i2c-<N>` is that adapter's node.

 Source: Documentation/gpu/drm-kms.rst (the connector `ddc` link, created from
 `connector->ddc`); Documentation/i2c/dev-interface.rst (`/dev/i2c-N`). The link
 is also what DankMaterialShell's `ddc.go` uses to map connectors to buses.
*>
module bleu::brightness::drm @feat(LINUX);
import std::collections::list, bleu::brightness::sysfs, bleu::error;

<* A connected connector and the I2C bus its DDC/CI lines are on. *>
struct Connector
{
	String name;
	int bus;
}

<* Room for the target of a `ddc` link: a path of a few dozen elements at most. *>
const sz LINK_CAPACITY = 256;

extern fn sz readlink(char* path, char* buffer, usz size);

<*
 The connected connectors under `root` that have a DDC/CI bus. Names are copied
 into `allocator`. Temporary values use the caller's scope, so call it inside a `@pool()`.

 @return? NOT_FOUND : "There is no DRM class; the kernel exposes no displays here"
*>
fn Connector[]? connectors(Allocator allocator, String root)
{
	if (!sysfs::has_class(root, sysfs::DRM_CLASS)) return NOT_FOUND~;
	String[] names = sysfs::entries(tmem, root, sysfs::DRM_CLASS)!;
	List{Connector} found;
	found.init(tmem);
	foreach (name : names)
	{
		if (!sysfs::is_connector_name(name)) continue;
		String dir    = string::tformat("%s%s/%s", root, sysfs::DRM_CLASS, name);
		String status = sysfs::read_text(tmem, dir, "status") ?? "";
		if (status != "connected") continue;
		if (try bus = bus_of(dir)) found.push({ .name = name.copy(allocator), .bus = bus });
	}
	return alloc::clone_slice(allocator, found.array_view());
}

// The I2C adapter a connector directory's `ddc` link points at.
fn int? bus_of(String dir) @private
{
	@pool()
	{
		char[LINK_CAPACITY] target;
		sz length = readlink(string::tformat("%s/ddc", dir).zstr_tcopy(), &target, target.len);
		if (length <= 0) return NOT_FOUND~;
		return sysfs::bus_from_link((String)target[0:(usz)length]);
	};
}