<*
 bleu_dbus: a D-Bus client in pure C3, with no libdbus, sd-bus or GLib.

 The modules, from the bottom up:

 * `bleu::dbus::signature` and `bleu::dbus::names`: type signatures and the
 grammar of names and object paths, with the limits of the specification.
 * `bleu::dbus::value`: `Value`, an owned dynamic tree of D-Bus values.
 * `bleu::dbus::marshal`: `Writer` and `Reader`, the wire format in both byte orders.
 * `bleu::dbus::message`: messages, their header fields, parsing and encoding.
 * `bleu::dbus::auth` and `bleu::dbus::address`: SASL EXTERNAL and bus addresses.
 * `bleu::dbus::transport`: Unix sockets and descriptor passing (POSIX; Windows
 raises UNSUPPORTED).
 * `bleu::dbus::connection`: `Connection`, the handshake, calls and dispatch.
 * `bleu::dbus::match` and `bleu::dbus::bus`: match rules, subscriptions, names.
 * `bleu::dbus::proxy`: remote objects, their properties and object trees.
 * `bleu::dbus::errors`: D-Bus error names as `bleu::error` excuses.

 Typical use:

 Connection bus;
 bus.init(alloc);
 defer bus.free();
 bus.open_session()!;
 Proxy login = proxy::for_object(&bus, "org.freedesktop.login1",
 "/org/freedesktop/login1", "org.freedesktop.login1.Manager")!;
 Value sessions = login.get_property("NAutoVTs", alloc)!;

 Server-side object export is not implemented yet.

 Sources for the whole library are listed in `docs/research/bleu_dbus.md`.
*>
module bleu::dbus;