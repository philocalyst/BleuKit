<*
 Introspection: the XML that `org.freedesktop.DBus.Introspectable.Introspect`
 returns for an object, generated from the interface tables and the exported
 paths.

 The XML lists the object's interfaces, its child nodes, and for an ObjectManager
 root the ObjectManager interface. The standard interfaces every object has
 (Peer, Introspectable, Properties) are implied, as the common libraries do,
 and are not listed. Descriptions follow the DTD in the specification, "Introspection
 Data Format"; python-dbus-next 0.2.3 parses the output in the integration test.
*>
module bleu::dbus::server;
import bleu::error, bleu::dbus::signature, bleu::dbus::value;
import std::collections::list;

<* The DOCTYPE line of every introspection document. *>
const XML_DOCTYPE = "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"\n \"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n";

<* The annotation that names the property's `EmitsChangedSignal` rule. *>
const ANNOTATION_EMITS_CHANGED = "org.freedesktop.DBus.Property.EmitsChangedSignal";

<*
 The introspection XML of the object at `path`. A path with no object but with
 objects below it describes a node with children, as the specification allows.

 Use `has_node` first to tell an unknown path from an empty node.

 @return "The XML document, in `allocator`"
*>
fn String ObjectServer.introspection(&self, String path, Allocator allocator)
{
	DString out;
	out.init(allocator);
	defer out.free();
	out.append_string(XML_DOCTYPE);
	out.append_string("<node>\n");
	Target target = self.find_target(path);
	if (target.found)
	{
		for (sz k = 0; k < target.interfaces.len; k++) write_interface(&out, &target.interfaces[k]);
		if (target.manager) write_object_manager(&out);
	}
	self.write_children(&out, path);
	out.append_string("</node>\n");
	return out.copy_str(allocator);
}

<*
 True when Introspect can describe `path`: an object is served there, or an
 exported object lies below it.
*>
fn bool ObjectServer.has_node(&self, String path)
{
	if (self.find_target(path).found) return true;
	foreach (e : self.exports)
	{
		if (is_below(e.path.str_view(), path)) return true;
	}
	return false;
}

// Answers Introspect() -> s for the path of the call.
fn void? introspect_call(Call* c) @private
{
	if (!arguments_are(c, "")) return c.reply_error(ERROR_INVALID_ARGS, "Introspect takes no arguments");
	if (!c.server.has_node(c.path)) return c.reply_error(ERROR_UNKNOWN_OBJECT, string::tformat("no object at %s", c.path));
	String xml = c.server.introspection(c.path, tmem);
	Value[] out = { value::str(tmem, xml)! };
	return c.reply(out);
}

// Writes one `<node name=...>` for each distinct next element of the exported paths below `path`.
fn void ObjectServer.write_children(&self, DString* out, String path)
{
	@pool()
	{
		List{String} seen;
		seen.init(tmem);
		sz start = path == "/" ? 1 : path.len + 1;
		foreach (e : self.exports)
		{
			if (!is_below(e.path.str_view(), path)) continue;
			String full = e.path.str_view();
			sz end = start;
			while (end < full.len && full[end] != '/') end++;
			String child = full[start : end - start];
			if (contains_text(&seen, child)) continue;
			seen.push(child);
			out.append_string("  <node name=\"");
			append_escaped(out, child);
			out.append_string("\"/>\n");
		}
	};
}

// True when `list` already holds `text`.
fn bool contains_text(List{String}* list, String text) @private
{
	foreach (item : list)
	{
		if (item == text) return true;
	}
	return false;
}

// Writes one `<interface>` element with its methods, signals and properties.
fn void write_interface(DString* out, Interface* i) @private
{
	out.append_string("  <interface name=\"");
	append_escaped(out, i.name);
	out.append_string("\">\n");
	for (sz k = 0; k < i.methods.len; k++) write_method(out, &i.methods[k]);
	for (sz k = 0; k < i.signals.len; k++) write_signal(out, &i.signals[k]);
	for (sz k = 0; k < i.properties.len; k++) write_property(out, &i.properties[k]);
	out.append_string("  </interface>\n");
}

// Writes one `<method>` with its in and out arguments.
fn void write_method(DString* out, Method* m) @private
{
	out.append_string("    <method name=\"");
	append_escaped(out, m.name);
	out.append_string("\">\n");
	write_args(out, m.in_signature, m.in_names, "in", "      ");
	write_args(out, m.out_signature, m.out_names, "out", "      ");
	out.append_string("    </method>\n");
}

// Writes one `<signal>` with its arguments.
fn void write_signal(DString* out, Signal* s) @private
{
	out.append_string("    <signal name=\"");
	append_escaped(out, s.name);
	out.append_string("\">\n");
	write_args(out, s.signature, s.arg_names, "", "      ");
	out.append_string("    </signal>\n");
}

// Writes one `<property>` with its type, access and EmitsChangedSignal annotation.
fn void write_property(DString* out, Property* p) @private
{
	out.append_string("    <property name=\"");
	append_escaped(out, p.name);
	out.append_string("\" type=\"");
	append_escaped(out, p.signature);
	out.append_string("\" access=\"");
	out.append_string(access_text(p.access));
	out.append_string("\">\n      <annotation name=\"");
	out.append_string(ANNOTATION_EMITS_CHANGED);
	out.append_string("\" value=\"");
	out.append_string(changes_text(p.changes));
	out.append_string("\"/>\n    </property>\n");
}

// Writes one `<arg>` per complete type of `sig`. `direction` is "in", "out", or "" for a signal.
fn void write_args(DString* out, String sig, String[] names, String direction, String indent) @private
{
	TypeIterator it = signature::iterate(sig);
	for (sz k = 0; it.has_next(); k++)
	{
		String arg_type = it.next()!!;
		out.append_string(indent);
		out.append_string("<arg");
		if (names.len > 0)
		{
			out.append_string(" name=\"");
			append_escaped(out, names[k]);
			out.append_string("\"");
		}
		out.append_string(" type=\"");
		append_escaped(out, arg_type);
		out.append_string("\"");
		if (direction.len > 0)
		{
			out.append_string(" direction=\"");
			out.append_string(direction);
			out.append_string("\"");
		}
		out.append_string("/>\n");
	}
}

// The `access` attribute for an access.
fn String access_text(PropertyAccess access) @private
{
	switch (access)
	{
		case READ: return "read";
		case WRITE: return "write";
		case READ_WRITE: return "readwrite";
	}
}

// The value of the EmitsChangedSignal annotation for a change rule.
fn String changes_text(ChangeSignal changes) @private
{
	switch (changes)
	{
		case EMITS_CHANGED: return "true";
		case INVALIDATES: return "invalidates";
		case CONST: return "const";
		case NEVER: return "false";
	}
}

// Writes the ObjectManager interface, as an ObjectManager root describes it.
fn void write_object_manager(DString* out) @private
{
	out.append_string("  <interface name=\"org.freedesktop.DBus.ObjectManager\">\n");
	out.append_string("    <method name=\"GetManagedObjects\">\n");
	out.append_string("      <arg name=\"objpath_interfaces_and_properties\" type=\"a{oa{sa{sv}}}\" direction=\"out\"/>\n");
	out.append_string("    </method>\n");
	out.append_string("    <signal name=\"InterfacesAdded\">\n");
	out.append_string("      <arg name=\"object_path\" type=\"o\"/>\n");
	out.append_string("      <arg name=\"interfaces_and_properties\" type=\"a{sa{sv}}\"/>\n");
	out.append_string("    </signal>\n");
	out.append_string("    <signal name=\"InterfacesRemoved\">\n");
	out.append_string("      <arg name=\"object_path\" type=\"o\"/>\n");
	out.append_string("      <arg name=\"interfaces\" type=\"as\"/>\n");
	out.append_string("    </signal>\n");
	out.append_string("  </interface>\n");
}

// Writes `text` with the characters that are special in XML attributes escaped.
fn void append_escaped(DString* out, String text) @private
{
	foreach (c : text)
	{
		switch (c)
		{
			case '&': out.append_string("&amp;");
			case '<': out.append_string("&lt;");
			case '>': out.append_string("&gt;");
			case '"': out.append_string("&quot;");
			default: out.append_char(c);
		}
	}
}
