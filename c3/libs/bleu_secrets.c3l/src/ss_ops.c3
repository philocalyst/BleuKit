<*
 The five requests, against the Secret Service objects. Each function does
 one request and returns its result; the worker's `execute` completes the
 operation with it.

 Items are found by lookup attributes that include `bleu.owner = bleu`, so
 only items this library wrote are read, searched or deleted.
*>
module bleu::secrets::ss @feat(LINUX);
import std::atomic;
import std::collections::list, std::collections::maybe, std::time, bleu::error, bleu::dbus::message, bleu::dbus::proxy, bleu::dbus::value, bleu::dbus::marshal, bleu::secrets, bleu::secrets::session, bleu::service;

<* Attributes the library writes on every item, and reads back on search. *>
fn void? write_pair(Writer* w, String key, String text)
{
	w.begin_dict_entry()!;
	w.append_string(key)!;
	w.append_string(text)!;
	w.end_dict_entry()!;
}

<*
 Write the lookup dictionary "a{ss}": the owner marker, the service and account
 when they are set, then the caller's attributes.
*>
fn void? write_lookup(Writer* w, Entry entry)
{
	w.begin_array("a{ss}")!;
	write_pair(w, OWNER_KEY, OWNER_VALUE)!;
	if (entry.service.len > 0) write_pair(w, SERVICE_KEY, entry.service)!;
	if (entry.account.len > 0) write_pair(w, ACCOUNT_KEY, entry.account)!;
	foreach (attribute : entry.attributes) write_pair(w, attribute.key, attribute.value)!;
	w.end_array()!;
}

<* The a{sv} properties of a new item: its label and its attributes. *>
fn void? write_item_properties(Writer* w, Entry entry)
{
	w.begin_array("a{sv}")!;
	w.begin_dict_entry()!;
	w.append_string(ITEM_LABEL)!;
	w.begin_variant("s")!;
	w.append_string(entry.label)!;
	w.end_variant()!;
	w.end_dict_entry()!;
	w.begin_dict_entry()!;
	w.append_string(ITEM_ATTRIBUTES)!;
	w.begin_variant("a{ss}")!;
	write_lookup(w, entry)!;
	w.end_variant()!;
	w.end_dict_entry()!;
	w.end_array()!;
}

<*
 Encode a value for the session: encrypted with a fresh IV when the session is
 encrypted, or as it is when the session is plain.
*>
fn WireSecret? seal(SsBackend* b, char[] value, Allocator allocator)
{
	WireSecret wire = { .session = b.session, .value = value, .content_type = CONTENT_TYPE };
	if (b.transport == ENCRYPTED)
	{
		char[session::AES_BLOCK] iv = session::random_iv()!;
		wire.parameters = alloc::clone_slice(allocator, iv[..]);
		wire.value = session::encrypt_cbc(allocator, b.key[..], iv[..], value)!;
	}
	return wire;
}

<*
 Decode a secret received from the service into `allocator`.

 @return? error::PROTOCOL : "An encrypted session returned a value without an IV"
*>
fn Secret? open_value(SsBackend* b, WireSecret wire, Allocator allocator)
{
	if (b.transport != ENCRYPTED)
	{
		Secret plain = { .bytes = alloc::clone_slice(allocator, wire.value) };
		return plain;
	}
	if (wire.parameters.len != session::AES_BLOCK)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "an encrypted secret has no IV")~;
	}
	Secret decrypted = { .bytes = session::decrypt_cbc(allocator, b.key[..], wire.parameters, wire.value)! };
	return decrypted;
}

<*
 Every item matching the lookup, split into unlocked and locked, appended to the
 two lists. Object paths live in `tmem`.
*>
fn void? find_items(SsBackend* b, Entry filter, List{String}* unlocked, List{String}* locked)
{
	Message* call = call_message(tmem, SERVICE_PATH, SERVICE_INTERFACE, "SearchItems")!;
	Writer* w     = call.body_writer("a{ss}")!;
	write_lookup(w, filter)!;
	w.finish()!;
	Value[] reply = invoke(b, call, tmem)!;
	append_paths(reply[0], unlocked)!;
	append_paths(reply[1], locked)!;
}

// Append every object path of an array of object paths to `into`.
fn void? append_paths(Value array, List{String}* into)
{
	Value items = array.unwrap();
	for (usz i = 0; i < items.count(); i++)
	{
		String path = items.at(i)!.as_object_path()!;
		into.push(path.copy(tmem));
	}
}

<*
 The first unlocked item matching `entry`. A locked match is unlocked first,
 through the default collection.

 @return? NOT_FOUND : "No item matches"
*>
fn String? unlocked_item(SsBackend* b, Entry entry, Atomic{bool}* cancel)
{
	List{String} unlocked;
	unlocked.init(tmem);
	List{String} locked;
	locked.init(tmem);
	find_items(b, entry, &unlocked, &locked)!;
	if (unlocked.array_view().len == 0 && locked.array_view().len > 0)
	{
		unlock_collection(b, cancel, entry.service, entry.account)!;
		find_items(b, entry, &unlocked, &locked)!;
	}
	if (unlocked.array_view().len == 0) return NOT_FOUND~;
	return unlocked.array_view()[0];
}

<*
 The identity of an entry: its service and account. Read, delete and store find items by it, as the
 other platforms do; the caller's other attributes describe the item and do not select it.
*>
fn Entry identity(Entry entry) @inline => { .service = entry.service, .account = entry.account };

<*
 Store a value under `entry`, replacing the entry with the same service and account. The new item is
 created first; the other items of that identity are removed only after it exists, so a store that fails
 or is dismissed leaves the previous entry in place.
*>
fn Entry? store(SsBackend* b, Entry entry, Secret value, Atomic{bool}* cancel)
{
	ensure_session(b)!;
	ensure_collection(b, cancel, entry.service, entry.account)!;
	if (read_locked(b)!) unlock_collection(b, cancel, entry.service, entry.account)!;
	WireSecret wire = seal(b, value.bytes, tmem)!;
	Message* call   = call_message(tmem, b.collection, COLLECTION_INTERFACE, "CreateItem")!;
	Writer* w       = call.body_writer("a{sv}(oayays)b")!;
	write_item_properties(w, entry)!;
	write_secret(w, wire)!;
	w.append_bool(true)!;
	w.finish()!;
	Value[] reply = invoke(b, call, tmem)!;
	String prompt = reply[1].as_object_path()!;
	if (prompt != NO_OBJECT) run_prompt(b, prompt, cancel, entry.service, entry.account)!;
	remove_superseded(b, entry, cancel)!;
	emit(b, STORED, entry.service, entry.account);
	return entry;
}

<*
 Delete every item of the identity of `entry` whose attributes are not exactly `entry`'s. The item just
 stored has exactly those attributes, so it stays. The Secret Service replaces only an item with the same
 attributes, so without this an older item with other attributes would be found, and read, after the store.
*>
fn void? remove_superseded(SsBackend* b, Entry entry, Atomic{bool}* cancel)
{
	List{String} unlocked;
	unlocked.init(tmem);
	List{String} locked;
	locked.init(tmem);
	find_items(b, identity(entry), &unlocked, &locked)!;
	foreach (path : unlocked.array_view())
	{
		if (!has_attributes(b, path, entry)!) delete_item(b, path, cancel, entry)!;
	}
	foreach (path : locked.array_view())
	{
		if (!has_attributes(b, path, entry)!) delete_item(b, path, cancel, entry)!;
	}
}

// True when the item at `path` has exactly the caller attributes of `entry`. The owner marker and the
// service and account are not counted: `item_entry` leaves them out of its attributes.
fn bool? has_attributes(SsBackend* b, String path, Entry entry)
{
	Entry current = item_entry(b, path, tmem)!;
	if (current.attributes.len != entry.attributes.len) return false;
	foreach (wanted : entry.attributes)
	{
		if (!has_pair(current.attributes, wanted)) return false;
	}
	return true;
}

// True when `attributes` holds the key and value of `wanted`.
fn bool has_pair(Attribute[] attributes, Attribute wanted) @private
{
	foreach (attribute : attributes)
	{
		if (attribute.key == wanted.key && attribute.value == wanted.value) return true;
	}
	return false;
}

<* The value of the entry matching `entry`, copied into `allocator`. *>
fn Secret? read_value(SsBackend* b, Entry entry, Atomic{bool}* cancel, Allocator allocator)
{
	ensure_session(b)!;
	ensure_collection(b, cancel, entry.service, entry.account)!;
	String item   = unlocked_item(b, identity(entry), cancel)!;
	Message* call = call_message(tmem, item, ITEM_INTERFACE, "GetSecret")!;
	Writer* w     = call.body_writer("o")!;
	w.append_object_path(b.session)!;
	w.finish()!;
	Value[] reply   = invoke(b, call, tmem)!;
	WireSecret wire = read_secret(reply[0], tmem)!;
	return open_value(b, wire, allocator);
}

<*
 Delete every item matching `entry`. Locked matches are unlocked first.

 @return "true when something was deleted; false when nothing matched"
*>
fn bool? delete_entry(SsBackend* b, Entry entry, Atomic{bool}* cancel)
{
	ensure_session(b)!;
	ensure_collection(b, cancel, entry.service, entry.account)!;
	List{String} unlocked;
	unlocked.init(tmem);
	List{String} locked;
	locked.init(tmem);
	find_items(b, identity(entry), &unlocked, &locked)!;
	if (unlocked.array_view().len == 0 && locked.array_view().len == 0) return false;
	if (locked.array_view().len > 0) unlock_collection(b, cancel, entry.service, entry.account)!;
	foreach (path : unlocked.array_view()) delete_item(b, path, cancel, entry)!;
	foreach (path : locked.array_view()) delete_item(b, path, cancel, entry)!;
	emit(b, DELETED, entry.service, entry.account);
	return true;
}

// Delete one item, running its prompt when the service asks for one.
fn void? delete_item(SsBackend* b, String path, Atomic{bool}* cancel, Entry entry)
{
	Message* call = call_message(tmem, path, ITEM_INTERFACE, "Delete")!;
	Value[] reply = invoke(b, call, tmem)!;
	String prompt = reply[0].as_object_path()!;
	if (prompt != NO_OBJECT) run_prompt(b, prompt, cancel, entry.service, entry.account)!;
}

<*
 The entries matching `filter`, without values, copied into `allocator`.
 Locked and unlocked matches are both listed: their attributes are public.
*>
fn Entry[]? search_entries(SsBackend* b, Entry filter, Allocator allocator)
{
	ensure_session(b)!;
	List{String} unlocked;
	unlocked.init(tmem);
	List{String} locked;
	locked.init(tmem);
	find_items(b, filter, &unlocked, &locked)!;
	List{Entry} found;
	found.init(tmem);
	foreach (path : unlocked.array_view()) found.push(item_entry(b, path, allocator)!);
	foreach (path : locked.array_view()) found.push(item_entry(b, path, allocator)!);
	return alloc::clone_slice(allocator, found.array_view());
}

<* The entry an item stands for: its attributes, label and timestamps. *>
fn Entry? item_entry(SsBackend* b, String path, Allocator allocator)
{
	Proxy item       = proxy::for_object(&b.bus, BUS_NAME, path, ITEM_INTERFACE)!;
	Value attributes = item.get_property("Attributes", tmem)!.unwrap();
	List{Attribute} extra;
	extra.init(allocator);
	for (usz i = 0; i < attributes.count(); i++)
	{
		Value pair = attributes.at(i)!;
		String key = pair.items[0].as_string()!;
		if (key.starts_with("bleu.")) continue;
		extra.push({ .key = key.copy(allocator), .value = pair.items[1].as_string()!.copy(allocator) });
	}
	String label = item.get_string("Label", allocator) ?? "";
	Entry entry = {
		.service = text_of(&attributes, SERVICE_KEY, allocator),
		.account = text_of(&attributes, ACCOUNT_KEY, allocator),
		.label = label,
		.attributes = extra.array_view(),
	};
	if (try created = item.get_property("Created", tmem)) entry.created = maybe::value(unix_time(created.as_u64()!));
	if (try modified = item.get_property(
		"Modified",
		tmem
	)) entry.modified = maybe::value(unix_time(modified.as_u64()!));
	return entry;
}

// The text of one key of an a{ss} value, or "" when the key is absent.
fn String text_of(Value* dict, String key, Allocator allocator)
{
	if (try found = dict.dict_get(key))
	{
		if (try text = found.as_string()) return text.copy(allocator);
	}
	return "";
}

<* A timestamp given as seconds since the Unix epoch, as the Secret Service reports them. *>
// std::time counts microseconds from the Unix epoch, which is where `time::now()` starts too.
fn Time unix_time(
	ulong seconds
) => ((Time)0).add_seconds((long)seconds);

<*
 Unlock the default collection if it is locked. Explicit unlock requests use this.

 @return "The lock state after the request"
*>
fn Lock? unlock_keyring(SsBackend* b, Atomic{bool}* cancel)
{
	ensure_session(b)!;
	ensure_collection(b, cancel, "", "")!;
	if (read_locked(b)!) unlock_collection(b, cancel, "", "")!;
	refresh_lock(b);
	return b.lock;
}